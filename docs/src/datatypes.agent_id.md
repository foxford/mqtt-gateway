# AgentId

`AgentId` is a compound FQDN like identifier of an agent.

```bash
${AGENT_LABEL}.${ACCOUNT_ID}
```

Name             | Type      | Default    | Description
---------------- | --------- | ---------- | ------------------
AGENT_LABEL      | String    | _required_ | A label describing a particular agent of the account, like web or mobile.
ACCOUNT_ID       | AccountId | _required_ | An account identifier of the agent.



**Example**

```bash
web.john-doe.usr.example.net
```
Where
- `web` is the agent label.
- `john-doe.usr.example.net` is the account ientifier.
