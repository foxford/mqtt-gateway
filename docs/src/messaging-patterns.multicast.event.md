## Multicast event

An event that may be processed by any agent of the particular application.

**Topic**

```bash
agents/${SENDER_AGENT_ID}/api/${RECIPIENT_VERSION}/out/${RECIPIENT_ACCOUNT_ID}
```

**Topic parameters**

Name                 | Type      | Default    | Description
-------------------- | --------- | ---------- | ------------------
SENDER_AGENT_ID      | AgentId   | _required_ | An agent identifier sending the event.
RECIPIENT_VERSION    | String    | _required_ | A version of an application receiving the event.
RECIPIENT_ACCOUNT_ID | AccountId | _required_ | An account identifier of the application receiving the event.

**Properties**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
type               | String  | _required_ | Always `event`.
label              | String  | _required_ | A label describing the event.
