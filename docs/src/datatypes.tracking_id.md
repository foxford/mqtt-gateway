# TrackingId

`TrackingId` is a compound FQDN like identifier of a message series.

```bash
${TRACKING_LABEL}.${SESSION_ID}
```

Name            | Type      | Default    | Description
--------------- | --------- | ---------- | ------------------
TRACKING_LABEL  | Uuid      | _required_ | An identifier of the initial message of the series.
SESSION_ID      | SessionId | _required_ | A session id.



**Example**

```bash
1b671a64-40d5-491e-99b0-da01ff1f3341.123e4567-e89b-12d3-a456-426655440000.00112233-4455-6677-8899-aabbccddeeff
```
Where
- `1b671a64-40d5-491e-99b0-da01ff1f3341` is the tracking label.
- `123e4567-e89b-12d3-a456-426655440000.00112233-4455-6677-8899-aabbccddeeff` is the session id.
