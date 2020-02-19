# SessionId

`SessionId` is a compound FQDN like identifier of an agent session.

```bash
${AGENT_SESSION_LABEL}.${BROKER_SESSION_LABEL}
```

Name                 | Type    | Default    | Description
-------------------- | ------- | ---------- | ------------------
AGENT_SESSION_LABEL  | Uuid    | _required_ | A session label of the agent.
BROKER_SESSION_LABEL | Uuid    | _required_ | A session label of the broker.



**Example**

```bash
123e4567-e89b-12d3-a456-426655440000.00112233-4455-6677-8899-aabbccddeeff
```
Where
- `123e4567-e89b-12d3-a456-426655440000` is the session label of the agent.
- `00112233-4455-6677-8899-aabbccddeeff` is the session label of the broker.
