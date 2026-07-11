/**
 * computeUnits.ts — converts equal USD weights into immutable raw
 * unitsPerBasket at deploy time, using fresh Chainlink prices.
 *
 * Usage:
 *   RH_RPC=https://...  GUARDIAN=0x...  FEE_RECIPIENT=0x...  npm run compute-units
 *
 * Hard safety rails (spec WP-2):
 *   - refuses to run if any feed is stale (updatedAt older than heartbeat)
 *     → effectively must be run during US market hours;
 *   - refuses if a token reports oraclePaused() (corporate action running);
 *   - refuses if the L2 sequencer uptime feed (when configured) reports down;
 *   - reads symbol()/decimals() from the live chain and aborts on mismatch;
 *   - requires the operator to type `verified` confirming the addresses were
 *     re-checked against https://docs.robinhood.com/chain/contracts.
 */
import { createPublicClient, http, defineChain, getAddress, type Address } from "viem";
import { readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dir = dirname(fileURLToPath(import.meta.url));

const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RH_RPC ?? ""] } },
});

const aggregatorAbi = [
  {
    name: "latestRoundData",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const;

const tokenAbi = [
  { name: "symbol", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { name: "oraclePaused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

type PoolCfg = {
  poolManager: string;
  poolId: string;
  quote: "USDG" | "ETH";
  tokenIs0: boolean;
};
type ConstituentCfg = {
  token: string;
  feed: string | null;
  heartbeatSeconds: number;
  /** price source for feed-less assets (memes): their own v4 pool */
  pool?: PoolCfg;
};
type BasketCfg = {
  name: string;
  symbol: string;
  outputFile: string;
  tickers: string[];
  targetUsdPerBasket: number;
  mintFeeBps: number;
  maxSupplyCap: string;
  initialSupplyCap: string;
};
type Config = {
  sequencerUptimeFeed: string | null;
  constituents: Record<string, ConstituentCfg>;
  baskets: BasketCfg[];
};

function fail(msg: string): never {
  console.error(`\n✖ ABORT: ${msg}`);
  process.exit(1);
}

/** Uniswap v4 PoolManager Swap event topic. */
const SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";
/** Chainlink ETH/USD on Robinhood Chain (dollarizes ETH-quoted pools). */
const ETH_USD_FEED = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9";

/**
 * Spot for a pool-priced asset (memes): the last Swap in its v4 pool over
 * the past day, converted to 1e8 USD. Assumes the asset has 18 decimals
 * (enforced above) and quotes against USDG (6 dec) or native ETH (18 dec).
 */
async function poolSpot(
  client: ReturnType<typeof createPublicClient>,
  pool: PoolCfg,
  now: bigint,
  _config: Config,
): Promise<{ price8: bigint; age: bigint }> {
  const latest = await client.getBlock();
  // progressive lookback: busy pools answer in the first window, and wide
  // windows on busy pools time the RPC out
  let logs: { blockNumber: string; data: string }[] = [];
  for (const lookback of [20_000n, 200_000n, 900_000n]) {
    const fromBlock = latest.number > lookback ? latest.number - lookback : 1n;
    try {
      logs = (await client.request({
        method: "eth_getLogs" as never,
        params: [
          {
            address: getAddress(pool.poolManager),
            topics: [SWAP_TOPIC, pool.poolId],
            fromBlock: `0x${fromBlock.toString(16)}`,
            toBlock: "latest",
          },
        ] as never,
      })) as { blockNumber: string; data: string }[];
    } catch {
      continue; // window too heavy for the RPC: a narrower one already ran or none will work
    }
    if (logs.length) break;
  }
  if (!logs.length) fail(`pool ${pool.poolId.slice(0, 10)}…: no trades found in the last ~25h`);

  const last = logs[logs.length - 1];
  const d = last.data.slice(2);
  const sqrt = Number(BigInt("0x" + d.slice(128, 192)));
  if (!sqrt) fail(`pool ${pool.poolId.slice(0, 10)}…: zero price in last swap`);
  const raw = (sqrt / 2 ** 96) ** 2; // currency1 raw per currency0 raw
  const perToken = pool.tokenIs0 ? raw : 1 / raw;

  let priceUsd: number;
  if (pool.quote === "USDG") {
    priceUsd = perToken * 1e12; // 18 dec token -> 6 dec USDG
  } else {
    const [, ethAnswer] = await client.readContract({
      address: getAddress(ETH_USD_FEED),
      abi: aggregatorAbi,
      functionName: "latestRoundData",
    });
    priceUsd = perToken * (Number(ethAnswer) / 1e8);
  }
  if (!Number.isFinite(priceUsd) || priceUsd <= 0) fail(`pool spot computed non-positive price`);

  const lastBn = BigInt(last.blockNumber);
  const age = ((latest.number - lastBn) * 1n) / 10n; // ~0.1s blocks
  return { price8: BigInt(Math.round(priceUsd * 1e8)), age };
}

async function main() {
  const rpc = process.env.RH_RPC ?? fail("RH_RPC env var is required");
  const guardian = getAddress(process.env.GUARDIAN ?? fail("GUARDIAN env var is required (Safe address)"));
  const feeRecipient = getAddress(process.env.FEE_RECIPIENT ?? fail("FEE_RECIPIENT env var is required"));

  const config: Config = JSON.parse(readFileSync(resolve(__dir, "config/constituents.json"), "utf8"));
  // optional filter: BASKETS=TECH5,GPU,MEME5 prices and writes only those,
  // so future baskets with weekend-stale feeds don't block a generation run
  const only = (process.env.BASKETS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (only.length) {
    config.baskets = config.baskets.filter((b) => only.includes(b.symbol));
    if (!config.baskets.length) fail(`BASKETS filter matched nothing: ${only.join(",")}`);
    console.log(`(BASKETS filter active: ${config.baskets.map((b) => b.symbol).join(", ")})`);
  }
  const client = createPublicClient({ chain: robinhoodChain, transport: http(rpc) });

  const chainId = await client.getChainId();
  if (chainId !== 4663) fail(`connected to chain ${chainId}, expected Robinhood Chain (4663)`);

  // --- L2 sequencer check (Chainlink convention: answer 0 = up) ------------
  if (config.sequencerUptimeFeed) {
    const [, answer, startedAt] = await client.readContract({
      address: getAddress(config.sequencerUptimeFeed),
      abi: aggregatorAbi,
      functionName: "latestRoundData",
    });
    if (answer !== 0n) fail("L2 sequencer uptime feed reports sequencer DOWN");
    if (BigInt(Math.floor(Date.now() / 1000)) - startedAt < 3600n) {
      fail("sequencer restarted <1h ago — wait for the grace period");
    }
  } else {
    console.warn("⚠ no sequencerUptimeFeed configured — skipping sequencer check");
  }

  // --- price reads with per-feed validation --------------------------------
  const now = BigInt(Math.floor(Date.now() / 1000));
  const prices = new Map<string, bigint>(); // ticker → price in 1e8 USD

  const needed = new Set(config.baskets.flatMap((b) => b.tickers));
  for (const ticker of needed) {
    const c = config.constituents[ticker] ?? fail(`no constituent config for ${ticker}`);
    if (!c.feed && !c.pool) {
      fail(`${ticker} has neither a Chainlink feed nor a pool price source — fill scripts/config/constituents.json`);
    }

    const token = getAddress(c.token);

    const [onChainSymbol, tokenDecimals] = await Promise.all([
      client.readContract({ address: token, abi: tokenAbi, functionName: "symbol" }),
      client.readContract({ address: token, abi: tokenAbi, functionName: "decimals" }),
    ]);
    if (tokenDecimals !== 18) fail(`${ticker}: token reports ${tokenDecimals} decimals, expected 18`);
    // compare ignoring spacing/punctuation ("VIBE CAT" vs VIBECAT is fine;
    // a different name entirely still aborts)
    const normSymbol = onChainSymbol.toUpperCase().replace(/[^A-Z0-9]/g, "");
    const normTicker = ticker.toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!normSymbol.includes(normTicker)) {
      fail(`${ticker}: on-chain symbol is "${onChainSymbol}" — address/ticker mismatch, possible fake token`);
    }

    // Advisory corporate-action flag on the token (may not exist on all tokens).
    try {
      const paused = await client.readContract({ address: token, abi: tokenAbi, functionName: "oraclePaused" });
      if (paused) fail(`${ticker}: oraclePaused() is true — corporate action in progress, do not price now`);
    } catch {
      console.warn(`⚠ ${ticker}: oraclePaused() not readable — continuing (advisory flag only)`);
    }

    if (c.feed) {
      const feed = getAddress(c.feed);
      const [feedDecimals, roundData] = await Promise.all([
        client.readContract({ address: feed, abi: aggregatorAbi, functionName: "decimals" }),
        client.readContract({ address: feed, abi: aggregatorAbi, functionName: "latestRoundData" }),
      ]);
      const [, answer, , updatedAt] = roundData;
      if (answer <= 0n) fail(`${ticker}: feed answer ${answer} is not positive`);
      const age = now - updatedAt;
      if (age > BigInt(c.heartbeatSeconds)) {
        fail(
          `${ticker}: feed is STALE (updated ${age}s ago, heartbeat ${c.heartbeatSeconds}s). ` +
            `Feeds update 24/5 — run during US market hours.`,
        );
      }

      // Normalize to 1e8
      const price8 = feedDecimals === 8 ? answer : (answer * 10n ** 8n) / 10n ** BigInt(feedDecimals);
      prices.set(ticker, price8);
      console.log(`  ${ticker.padEnd(6)} $${(Number(price8) / 1e8).toFixed(2)}  (age ${age}s, feed ok)`);
    } else {
      const { price8, age } = await poolSpot(client, c.pool!, now, config);
      if (age > BigInt(c.heartbeatSeconds)) {
        fail(`${ticker}: last pool trade is ${age}s old (heartbeat ${c.heartbeatSeconds}s) — market too quiet to price`);
      }
      prices.set(ticker, price8);
      console.log(`  ${ticker.padEnd(6)} $${(Number(price8) / 1e8).toFixed(6)}  (last trade ${age}s ago, pool ok)`);
    }
  }

  // --- human checkpoint -----------------------------------------------------
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await rl.question(
    "\nHave you re-verified every token address against https://docs.robinhood.com/chain/contracts ?\n" +
      "Type 'verified' to continue: ",
  );
  rl.close();
  if (answer.trim() !== "verified") fail("operator did not confirm address verification");

  // --- units math -----------------------------------------------------------
  // Equal weight: each constituent backs (target/n) USD per 1e18 basket wei.
  // units_i [raw wei / 1e18 basket wei] = (target/n) / price_i * 1e18
  //   = target * 1e8 * 1e18 / (n * price8_i)   (floor; target value is cosmetic)
  for (const basket of config.baskets) {
    const n = BigInt(basket.tickers.length);
    const tokens: string[] = [];
    const units: string[] = [];
    for (const ticker of basket.tickers) {
      const price8 = prices.get(ticker)!;
      const u = (BigInt(basket.targetUsdPerBasket) * 10n ** 8n * 10n ** 18n) / (n * price8);
      if (u === 0n) fail(`${basket.symbol}/${ticker}: computed units are zero`);
      tokens.push(getAddress(config.constituents[ticker].token));
      units.push(u.toString());
    }

    const out = {
      name: basket.name,
      symbol: basket.symbol,
      tokens,
      unitsPerBasket: units,
      mintFeeBps: basket.mintFeeBps,
      feeRecipient,
      guardian,
      maxSupplyCap: basket.maxSupplyCap,
      initialSupplyCap: basket.initialSupplyCap,
      _meta: {
        generatedAt: new Date().toISOString(),
        chainId,
        targetUsdPerBasket: basket.targetUsdPerBasket,
        pricesUsd8: Object.fromEntries(basket.tickers.map((t) => [t, prices.get(t)!.toString()])),
      },
    };
    const path = resolve(__dir, basket.outputFile);
    writeFileSync(path, JSON.stringify(out, null, 2) + "\n");
    console.log(`\n✔ ${basket.symbol}: wrote ${path}`);
  }

  console.log("\nNext: dry-run the deploy (no --broadcast), review the printed config, then broadcast with CONFIRM_DEPLOY=yes.");
}

main().catch((e) => fail(e?.message ?? String(e)));
