## Multicast request

A request that may be processed by any agent of the particular application.

**Topic**

```bash
agents/${SENDER_AGENT_ID}/api/${RECIPIENT_VERSION}/out/${RECIPIENT_ACCOUNT_ID}
```

**Topic parameters**

Name                 | Type      | Default    | Description
-------------------- | --------- | ---------- | ------------------
SENDER_AGENT_ID      | AgentId   | _required_ | An agent identifier sending the request.
RECIPIENT_VERSION    | String    | _required_ | A version of an application receiving the request.
RECIPIENT_ACCOUNT_ID | AccountId | _required_ | An account identifier of the application receiving the request.

**Properties**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
type               | String  | _required_ | Always `request`.
method             | String  | _required_ | A method of the application to call.
correlation_data   | String  | _required_ | The same value will be in a response to this request.
response_topic     | String  | _required_ | Always `agents/${SENDER_AGENT_ID}/api/${RECIPIENT_VERSION}/in/${RECIPIENT_ACCOUNT_ID}`.
