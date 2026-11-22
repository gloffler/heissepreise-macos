# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-22

First public release.

### Added
- **Data:** loads the per-retailer feeds from heisse-preise.io (BILLA, SPAR, HOFER, Lidl, PENNY, MPREIS, dm, Müller, BIPA, Unimarkt), caches them on disk and revalidates them with ETag / Last-Modified (`⌘R`).
- **Search:** in-memory, multi-word, accent-insensitive search over ~160,000 products in 1–4 ms per keystroke; `-word` excludes a word.
- **Results table:** retailer badge, product, quantity, unit price (€/kg, €/L, …), price, change in € and %, date of last change; sortable by every column or by relevance.
- **Filters:** retailers with presets (Alle, Diskonter, Rewe, SPAR), price trend (reduced, more expensive, all-time low), own brands, organic, only available, changed within N days, price and unit-price ranges, unit and package size, two-level categories, all with live counts.
- **Detail inspector:** full product facts, step chart of the complete price history with hover tooltip and 3M / 1J / 3J / Alles ranges, all-time low and high, time-weighted average.
- **Watchlist and pinned searches** with a badge for price changes since you last opened them.
- **Keyboard-first workflow:** `⌘F` / `⌘K`, `↑` `↓`, `↩︎`, `Esc`, `⌘C`, `⌘O`, `⌘D`, `⇧⌘D`, `⌃⌘1–9`.
- `pricebench` command-line benchmark for the search engine.

[Unreleased]: https://github.com/gloffler/heissepreise-macos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/gloffler/heissepreise-macos/releases/tag/v1.0.0
