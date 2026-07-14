# Capability — what this report can and cannot answer

Written so the next person doesn't spend a day rediscovering a dead end.

---

## It CAN answer

| Question | Where |
|---|---|
| Which return reasons cost the most refund money? | Reason tabs, sorted by refund |
| Which SKUs cost the most in refunds? | SKU tabs — **all** 817 Amazon / 310 eBay GBP rows, not a top-15 |
| Why is a given SKU coming back? | *Top Reason* column |
| How many **units** are involved, not just how many return events? | *Units* column (2,789 Amazon / 794 eBay) |
| Which marketplace does a SKU's returns come from? | *Marketplace* column, SKU tabs |
| Is a problem live or historical? | *Last Return* column |
| Is a reason one bad SKU, or spread across the catalogue? | Not yet a column — but measurable: `NOT_COMPATIBLE` spans **261 SKUs** |

## It CANNOT answer — verified, not assumed

**Return rate (returns ÷ units sold).** The metric everyone asks for first. It is
**not computable for Amazon**: `amazon_returns.sku` is a different key format from
`order_transaction.sku`, and only **699 of 1,503** return SKUs (46%) match *even all-time*.
A rate column would be blank or wrong for over half the rows. Computable for eBay alone
(its SKU comes from `order_transaction` by construction) — but a rate shown on one platform
and not the other invites exactly the wrong comparison, so it is deliberately absent.

**To unlock it:** someone must reconcile the Amazon SKU key. Until then, do not attempt it.

**"How much did returns really cost us?"** — only partially. See the two gaps below.

---

## Known gaps in the underlying data

**1. Amazon refund coverage is 42.7% incomplete.**
940 of 2,199 Amazon returns have `refunded_amount = NULL` (313 of 1,205 in GBP — 26%). They
contribute £0 not because they were free, but because the field is empty. Only 9 are
recoverable from `amz_order_expenses` (£555.30), so this is upstream data incompleteness, not
a query bug. **Consequence:** the Amazon KPI reads "Total Returns 1,205" beside "Total Refund
£21,412.33", which invites the false read that all 1,205 are costed. 892 are.
*Recommended fix: a one-line caption on the Amazon KPI card. Not yet applied.*

**2. Return shipping cost is not in the report.**
`amazon_returns.label_cost` holds **£5,157.26** in the window (83% populated) and is currently
ignored. `NOT_COMPATIBLE` shows as £5,665 of refund — its true cost is **£6,624**. Refunds are
not the whole bill.

**3. eBay operational risk is invisible.**
`ebay_returns.status` shows **15 ESCALATED returns (£507.91)** and **63 still open (12.9%)**.
Not surfaced.

---

## Deliberate design constraints — do not "fix" these

- **Currencies are never summed.** Both platforms are multi-currency. One currency is in scope
  at a time. A combined total is meaningless and is the exact error the task brief forbids —
  the brief's own SQL committed it by not noticing Amazon is multi-currency.
- **Amazon and eBay are never combined.** Different fee structures.
- **Marketplace is not on the Reason tabs.** A reason isn't a property of a marketplace;
  grouping by it would split every reason row. On the Reason tabs it would print a constant.
- **`% of Return Count` is share of count, while rows sort by refund.** These disagree
  (`NOT_COMPATIBLE`: 28.8% of count, 26.5% of refund). A *% of Refund* column would match the
  sort order. Offered, not yet taken.

---

## Scope not covered

Shopify (`public.shopify_returns` exists). Out of scope by instruction — may be added later.
Adding it means a third, separate section: never merged with the other two.
