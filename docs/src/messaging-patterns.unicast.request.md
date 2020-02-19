## Unicast request

A request that must be processed by the particular application's agent.

**Topic**

```bash
agents/${RECIPIENT_AGENT_ID}/api/${RECIPIENT_VERSION}/in/${SENDER_ACCOUNT_ID}
```

**Topic parameters**

Name               | Type      | Default    | Description
------------------ | --------- | ---------- | ------------------
RECIPIENT_AGENT_ID | AgentId   | _required_ | An agent identifier receiving the request.
RECIPIENT_VERSION  | String    | _required_ | A version of an application receiving the request.
SENDER_ACCOUNT_ID  | AccountId | _required_ | An account identifier of the application sending the request.

**Properties**

Name             | Type    | Default    | Description
---------------- | ------- | ---------- | ------------------
type             | String  | _required_ | Always `request`.
method           | String  | _required_ | A method of the application to call.
response_topic   | String  | _required_ | Always `agents/${SENDER_AGENT_ID}/api/${RECIPIENT_VERSION}/in/${RECIPIENT_ACCOUNT_ID}`.
correlation_data | String  | _required_ | The same value will be in a response to this request.