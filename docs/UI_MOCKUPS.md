# Expensify iOS — UI Direction (V1)

Standard iOS HIG. Native SwiftUI components, no third-party design system. Built around a 3-tab `TabView`, with Settings tucked behind an avatar in the nav bar.

---

## Information architecture

```
TabView (bottom)
├── Home          — welcome + transactions log + date filter
├── Categories    — spending-by-category breakdown + date filter
└── Activity      — swipe review queue (Tinder-style) + empty state

Top nav bar (every screen)
└── Avatar (top-right)  →  Settings sheet (.sheet modal)
                            └── Profile
                            └── Budgets per category
                            └── Sign out
```

Tab bar items — SF Symbols, two-state (regular / fill):

| Tab | Icon |
|---|---|
| Home | `house` / `house.fill` |
| Categories | `chart.pie` / `chart.pie.fill` |
| Activity | `bell` / `bell.fill` (with badge for pending count) |

---

## Screen 1 — Home

```
┌──────────────────────────────────┐
│ ◐                    Expensify   │   ← NavigationBar
│                                  │     • Avatar (left or right) → Settings
│                                  │     • Title centered or large
│   ──────────────────────────     │
│                                  │
│   Hi, welcome to Expensify       │   ← Headline (large title style)
│                                  │
│   May 2026  ▾                    │   ← Date-range Menu
│   ─────────                      │
│                                  │
│   Transactions                   │   ← Section header
│                                  │
│   ┌────────────────────────────┐ │
│   │ Swiggy             ₹547    │ │   ← TransactionRow component
│   │ Food · 09 May, 10:57       │ │     - amount right-aligned
│   └────────────────────────────┘ │     - subtitle: category · date
│   ┌────────────────────────────┐ │     - tap → detail view
│   │ Swiggy             ₹211    │ │
│   │ Food · 07 May, 21:15       │ │
│   └────────────────────────────┘ │
│   ┌────────────────────────────┐ │
│   │ SNEHA R              ₹1    │ │
│   │ P2P · 10 May, 18:00        │ │
│   └────────────────────────────┘ │
│         ⋮                        │
│                                  │
├──────────────────────────────────┤
│  ⌂ Home   ◔ Categories   🔔 Activity │  ← TabView
└──────────────────────────────────┘
```

**Date filter (top-right of section, or below welcome):**
- `Menu` with three options:
  - **Day** — opens DatePicker
  - **Month** — opens month/year wheel (default)
  - **Custom** — opens DateRangePicker (start + end)
- Selected range becomes the section subtitle: "May 2026" / "10 May 2026" / "01 May – 09 May"

**Transaction list:**
- `List` with `.plain` style for clean look (no card outlines), or `.insetGrouped` for grouped feel
- Pull-to-refresh
- Infinite scroll: paginated 50 at a time

---

## Screen 2 — Categories

```
┌──────────────────────────────────┐
│ ◐                  Categories    │
│                                  │
│   May 2026  ▾                    │   ← same date filter
│   ─────────                      │
│                                  │
│   Total spent      ₹6,140        │   ← summary card
│                                  │
│   ┌────────────────────────────┐ │
│   │ Food                       │ │   ← CategoryRow
│   │ ₹4,250            69%      │ │     - bar chart fill = % of total
│   │ ████████████░░░░░          │ │     - tap → list of transactions
│   └────────────────────────────┘ │       in that category
│   ┌────────────────────────────┐ │
│   │ Travel                     │ │
│   │ ₹1,200            20%      │ │
│   │ ████░░░░░░░░░░░░░          │ │
│   └────────────────────────────┘ │
│   ┌────────────────────────────┐ │
│   │ Personal Transfer          │ │
│   │ ₹500               8%      │ │
│   │ ██░░░░░░░░░░░░░░░          │ │
│   └────────────────────────────┘ │
│         ⋮                        │
│                                  │
├──────────────────────────────────┤
│  ⌂ Home   ◔ Categories   🔔 Activity │
└──────────────────────────────────┘
```

**Tapping a category** → push a screen showing transactions filtered to that category for the same date range (essentially Home's transaction list, pre-filtered).

---

## Screen 3a — Activity (swipe review, has items)

```
┌──────────────────────────────────┐
│ ◐                    Activity    │
│                                  │
│           3 of 7 to review       │   ← progress label
│                                  │
│                                  │
│      ┌──────────────────────┐    │
│      │                      │    │
│      │       ₹287           │    │   ← Card (top of stack)
│      │   RAJESH KUMAR       │    │     - amount large
│      │                      │    │     - merchant
│      │   Suggested: Travel  │    │     - suggested category
│      │   (rule: cab fare)   │    │     - "why?" tag
│      │                      │    │     - timestamp
│      │   Mon · 8:42 AM      │    │
│      │                      │    │
│      └──────────────────────┘    │
│                                  │
│                                  │
│   ← Needs tag        Looks ok →  │   ← swipe direction labels
│                                  │
│                                  │
├──────────────────────────────────┤
│  ⌂ Home   ◔ Categories   🔔 Activity │
└──────────────────────────────────┘
```

**Swipe semantics** (worth confirming — flagged as a design question below):

- **Swipe LEFT** → "Needs tag" → card flies left, item added to the post-swipe tagging list
- **Swipe RIGHT** → "Looks OK" → card flies right, item silently confirmed at its existing category, removed from review queue

After every card has been swiped, navigate to Screen 3c.

---

## Screen 3b — Activity (empty state)

```
┌──────────────────────────────────┐
│ ◐                    Activity    │
│                                  │
│                                  │
│                                  │
│            ✓                     │   ← SF Symbol "checkmark.seal"
│                                  │
│       All caught up              │   ← Title style
│                                  │
│   No transactions need review    │   ← Caption, secondary color
│                                  │
│                                  │
│                                  │
│                                  │
├──────────────────────────────────┤
│  ⌂ Home   ◔ Categories   🔔 Activity │
└──────────────────────────────────┘
```

Standard iOS empty state pattern (large symbol + title + caption).

---

## Screen 3c — Tagging list (after all cards swiped)

```
┌──────────────────────────────────┐
│ ✕                Tag 3 items     │   ← Modal nav with Cancel
│                                  │
│   ┌────────────────────────────┐ │
│   │ ₹287                       │ │
│   │ RAJESH KUMAR               │ │   ← TaggingRow
│   │ Mon · 8:42 AM              │ │     - txn details on top
│   │                            │ │     - dropdown picker bottom
│   │ Category                   │ │
│   │ ┌────────────────────┐     │ │
│   │ │ Travel          ▾  │     │ │   ← Picker / Menu, lists 7 cats
│   │ └────────────────────┘     │ │     - default: suggested category
│   └────────────────────────────┘ │     - user can override
│                                  │
│   ┌────────────────────────────┐ │
│   │ ₹94                        │ │
│   │ SRI GURU RAGHAVENDRA       │ │
│   │ Tue · 11:00 AM             │ │
│   │                            │ │
│   │ Category                   │ │
│   │ ┌────────────────────┐     │ │
│   │ │ Groceries       ▾  │     │ │
│   │ └────────────────────┘     │ │
│   └────────────────────────────┘ │
│         ⋮                        │
│                                  │
│   ┌──────────────────────────┐   │
│   │     Update Changes       │   │   ← Primary button, sticky bottom
│   └──────────────────────────┘   │     - bulk PATCH
│                                  │
└──────────────────────────────────┘
```

**Update Changes** → bulk-PATCH the chosen categories, dismiss back to Activity tab. If queue still has more items (unlikely; we processed all on swipe), they remain.

---

## Settings (sheet, not a tab)

Trigger: tap the avatar in the top nav bar of any screen → presents `.sheet`.

```
┌──────────────────────────────────┐
│  Done                  Settings  │   ← Modal nav, Done dismisses
│                                  │
│   Profile                        │   ← Section
│   ┌────────────────────────────┐ │
│   │ ◐  Sudhanva                │ │
│   │    sm.acharya@scaler.com   │ │
│   └────────────────────────────┘ │
│                                  │
│   Budgets                        │   ← Section
│   ┌────────────────────────────┐ │
│   │ Food            ₹5,000  >  │ │   ← row → push edit screen
│   ├────────────────────────────┤ │     - tap to edit limit
│   │ Travel          ₹3,000  >  │ │     - "Not set" if no budget
│   ├────────────────────────────┤ │
│   │ Entertainment   ₹1,500  >  │ │
│   ├────────────────────────────┤ │
│   │ Groceries       ₹2,000  >  │ │
│   ├────────────────────────────┤ │
│   │ P2P            Not set  >  │ │
│   ├────────────────────────────┤ │
│   │ Investments    Not set  >  │ │
│   ├────────────────────────────┤ │
│   │ Subscriptions   ₹800    >  │ │
│   └────────────────────────────┘ │
│                                  │
│   Account                        │
│   ┌────────────────────────────┐ │
│   │ Sign out                >  │ │
│   └────────────────────────────┘ │
└──────────────────────────────────┘
```

**Budget edit screen (push):**

```
┌──────────────────────────────────┐
│  ‹ Settings        Food          │
│                                  │
│   Monthly limit                  │
│   ┌────────────────────────────┐ │
│   │ ₹      5,000               │ │   ← TextField, decimal pad
│   └────────────────────────────┘ │
│                                  │
│   Alert thresholds               │
│   ┌────────────────────────────┐ │
│   │ Warn at 80%       (toggle) │ │
│   ├────────────────────────────┤ │
│   │ Notify at 100%    (toggle) │ │
│   ├────────────────────────────┤ │
│   │ Over budget at 110% (tog)  │ │
│   └────────────────────────────┘ │
│                                  │
│              ⋮                   │
│                                  │
│   ┌──────────────────────────┐   │
│   │       Save               │   │
│   └──────────────────────────┘   │
└──────────────────────────────────┘
```

---

## Component inventory (SwiftUI building blocks)

| Component | Used in | Notes |
|---|---|---|
| `TabView` | Root | 3 tabs |
| `NavigationStack` | Each tab | iOS 16+ |
| `Menu` | Date filters, dropdowns | system style |
| `List` | Transactions, categories, settings | `.insetGrouped` for settings, `.plain` for tx feed |
| `Picker` | Category dropdown | inline or wheel |
| `DatePicker` | Day filter | compact |
| `Sheet` | Settings | `.presentationDetents([.large])` |
| `DragGesture` | Card swipe | hand-rolled (no external dep) |
| `Spring animation` | Card fly-off | `.interpolatingSpring` |
| Haptics | On swipe complete | `UIImpactFeedbackGenerator(.light)` |

No third-party dependencies. All standard.

---

## Open design questions before implementation

1. **Swipe direction semantics** — your description was "swipe right means needs review". The Tinder convention is right=accept/keep, left=reject. Is the right=needs-tag direction intentional, or did you mean swipe right=looks OK / swipe left=needs tag (which would feel more natural)? I've drawn the **swipe LEFT = needs tag, swipe RIGHT = looks OK** version above as it matches conventional iOS gesture intuition. Easy to flip.

2. **Avatar position** — top-right is the iOS convention for user/settings menus (think Mail, Photos). Top-left is sometimes used for "primary action". I went top-right. OK?

3. **Budget alerts on/off vs slider** — I sketched per-threshold toggles (80% / 100% / 110%). Alternative: one slider for limit + automatic 3-tier alerts. Toggles give finer control; slider is cleaner.

4. **Empty state for Home/Categories** — what shows when no transactions exist for the date range? "No transactions in this range. Try a wider window." with a button to expand?

5. **Detail view for a single transaction** — tap a transaction row → push a detail screen with full info (raw merchant, VPA, location if any, category change, view email source). Worth building in V1, or skip until V2?

6. **Default category dropdown value in tagging list** — should it be the system's previous suggestion, or empty (force you to pick)? I chose pre-filled with the suggestion (saves taps).
