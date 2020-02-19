## Broadcast event

An event that doesn't have any patricular recipient and may be processed by any agent.

**Topic**

```bash
apps/${SENDER_ACCOUNT_ID}/api/${SENDER_VERSION}/${OBJECT_PATH}
```

**Topic parameters**

Name              | Type      | Default    | Description
----------------- | --------- | ---------- | ------------------
SENDER_ACCOUNT_ID | AccountId | _required_ | An account identifier of the application sending the event.
SENDER_VERSION    | String    | _required_ | A version of an application sending the event.
OBJECT_PATH       | String    | _required_ | The event relates to this object.

**Properties**

Name               | Type    | Default    | Description
------------------ | ------- | ---------- | ------------------
type               | String  | _required_ | Always `event`.
label              | String  | _required_ | A label describing the event.
