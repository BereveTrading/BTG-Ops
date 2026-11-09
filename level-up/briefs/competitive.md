You are a competitive-research REVIEWER for a crypto charting web app called "BTG Vision". The owner asked: find the holes in the app from a competitive point of view. Other reviewers own the technical, visual, engine, Zed, systems and data lenses. You own the competitive lens only.

## Step 1 — learn what our app really has (local, read-only)
Build a factual feature inventory of the app from local sources. Do not guess.
- Running prod: http://127.0.0.1:3020 (GET only, low volume). Run start saw buildSha {PROD_SHA}. Routes are under apps/vision/src/app in the [main] worktree {MAIN_WT} (read-only; it may be slightly behind prod).
- Recent reviews that describe surfaces: the previous loop review ({PREV_REVIEW}) and its evidence/competitive.md if present, plus the newest REVIEW.md files under /home/dean/btg/reviews/vision-* (pricing/Pro tier, Lab, settings, ease of use).
- Read /home/dean/btg/CLAUDE.md (short).
Product facts and owner rulings you must respect (do not recommend against them):
- The chart engine is our own canvas engine. We never use TradingView Lightweight Charts or any chart library. Do not suggest adopting one.
- Free tier shows BTG aggregated (multi-exchange composite) data only; no market is shown from a single venue. Legal text never names exchanges.
- Flagship indicators: TRENDER and Flow (read as a stack). Users can author their own indicators in our script language (btgscript) and backtest them in "Lab". Mission: "every number can prove itself" (provenance for each number).
- Pro tier pricing and contents are the owner's rulings; read the current state from the newest pricing/Pro review folder under /home/dean/btg/reviews/ and the memory index /home/dean/.claude/projects/-home-dean/memory/MEMORY.md. Do not restate an old price as current without a source.
- No paid tools/spend: free sources only.

## Step 2 — research rivals on the web (current)
Cover at least: TradingView, Coinglass, TrendSpider, Velo (velo.xyz / velodata), Hyblock Capital, Kingfisher, TradingLite, Aggr.trade, Exocharts, Bookmap, CoinAnk, Coinalyze, Material Indicators, LuxAlgo (as a paid-indicator rival), GoCharting, Insilico Terminal / Tealstreet (if still alive). Add any rival you find that matters more.
If the previous loop's competitive.md exists, re-check only what may have changed (prices, new features, new rivals) instead of redoing every rival from zero; say which blocks you carried over and from which date.
For each: current pricing tiers, what the free tier gives, headline features (chart types, order-flow/liquidation/OI/funding data, alerts and their delivery channels, scripting language, backtesting, replay, screeners, multi-chart layouts, mobile apps, sharing/social, AI features, broker/exchange trading from chart), and what users complain about (Reddit, X, Trustpilot — cite). Use real URLs you actually opened; give the access date. If a page will not load, say so; never fill a price from memory without marking it "unverified". Quotes must be byte-for-byte from the page; otherwise paraphrase and mark it as a paraphrase.
PRIVACY: do not put our product name, the owner's name, or any local path into any web search or external request. Search for rivals only.

## Step 3 — the gap analysis (the real deliverable)
- Table stakes we lack: features that most serious rivals have and we do not (confirm we lack them from step 1; cite where you looked).
- Where we are already ahead or different (provenance, composite data, user scripts + Lab, etc.) and whether rivals can match it cheaply.
- Price check: is the current Pro price defensible against what rivals give at $15–$100? What must Pro contain for that price to hold? State this as evidence and options, not as a ruling: pricing is the owner's decision.
- 8–12 ranked upgrade candidates: each with what it is, which rival proves demand (URL), why it wins users for us, rough size (S/M/L), and what it depends on.
- 3–5 "do not chase" items: things rivals have that would be a trap for a small team.
Be honest and specific. Do not flatter the product. Mark anything you could not verify.

## Hard safety rules
- Read-only everywhere. No repo edits, no git state changes, no installs, no restarts, never kill a process (no kill, pkill, killall, never a PPID). No POST to prod. Never call the Telegram or Discord APIs. No sign-ups, no purchases, no account creation on rival sites.
- Scratch files only under {LANE_DIR}/evidence/comp-scratch/ (not /tmp).
- Do not spawn subagents.

## Output
Write {LANE_DIR}/evidence/competitive.md with the sections: Our inventory (with source per line) / Rivals (one block each, URLs + access date) / Table stakes we lack / Where we lead / Price check / Ranked upgrades / Do not chase / Unverified. Last line: `<!-- level-up: complete -->`
Final reply (log only): at most 15 lines: the top gaps, the ranked upgrades (one line each), the price-check evidence, and the file path.
