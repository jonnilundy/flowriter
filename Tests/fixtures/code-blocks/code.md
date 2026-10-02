### Agent to process delinquency
- stripe webhook to trigger process
- agent has some sort of db to track open cases

```ts
const cases = await db.open()
for (const c of cases) remind(c)
```

The block above should read like code.
