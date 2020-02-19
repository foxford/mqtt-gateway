# Message properties set by the broker

**Authentication**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
agent_id           | AgentId | _required_ | An agent identifier of the sender.



**Connection**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
connection_version | String  | _required_ | A version the sender used to connect to the broker.
connection_mode    | String  | _required_ | A mode the sender used to connect to the broker.
broker_agent_id    | AgentId | _required_ | An agent identifier of the broker transmitting the message.



**Tracking a message series**

Name                   | Type        | Default    | Description
---------------------- | ----------- | ---------- | ------------------
tracking_id            | TrackingId  | _required_ | A compound identifier of the message series set by the broker.
session_tracking_label | [SessionId] | _required_ | The list of session identifiers of all the agent participating in the message series.
local_tracking_label   | String      | _optional_ | A label of the message series set by an agent of the initial message.
