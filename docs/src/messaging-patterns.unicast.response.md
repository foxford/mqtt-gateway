## Unicast response

A response sent to the particular agent.

**Topic**

```bash
agents/${RECIPIENT_AGENT_ID}/api/${RECIPIENT_VERSION}/in/${SENDER_ACCOUNT_ID}
```

**Topic parameters**

Name               | Type      | Default    | Description
------------------ | --------- | ---------- | ------------------
RECIPIENT_AGENT_ID | AgentId   | _required_ | An agent identifier receiving the response.
RECIPIENT_VERSION  | String    | _required_ | A version of an application receiving the response.
SENDER_ACCOUNT_ID  | AccountId | _required_ | An account identifier of the application sending the response.

**Properties**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
type               | String  | _required_ | Always `response`.
status             | String  | _required_ | A status code of the response. The value is HTTP compatible.
correlation_data   | String  | _required_ | The value from the same property of the initial request.