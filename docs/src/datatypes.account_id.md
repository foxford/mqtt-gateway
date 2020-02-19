# AccountId

`AccountId` is a compound FQDN like identifier of an account.

```bash
${ACCOUNT_LABEL}.${AUDIENCE}
```

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
ACCOUNT_LABEL      | String  | _required_ | An opaque tenant specific account label.
AUDIENCE           | String  | _required_ | An audience of the tenant.



**Example**

```bash
john-doe.usr.example.net
```
Where
- `john-doe` is the account label.
- `usr.example.net` is the audience.
