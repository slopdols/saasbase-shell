# Business Logic - Saasbase

This folder is the source of truth for product behavior. The generic shell has
no product-specific rules yet.

Add one document per business area as the product is defined:

- `overall-flow.md` - forest-level view, links to all other docs
- `user-types.md` - roles, auth, account lifecycle
- `data-models.md` - every entity, every field
- `payments.md` - money flows
- `security.md` - threat model

**Conflict resolution**: if a business-logic doc and the code disagree, report
it; code is authoritative for current behavior, the doc for intended behavior.
Do not "fix" one to match the other without asking.
