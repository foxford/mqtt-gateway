# Message properties set by the application

**Tracking time**

Name                                | Type    | Default    | Description
----------------------------------- | ------- | ---------- | ------------------
broker_initial_processing_timestamp | i64     | _required_ | Unix time in milliseconds the broker received the initial message of the series.
broker_processing_timestamp         | i64     | _required_ | Unix time in milliseconds the broker received the message.
broker_timestamp                    | i64     | _required_ | Unix time in milliseconds the broker transmitted the message.
local_initial_timediff              | i64     | _optional_ | Time difference in milliseconds between local time of an agent connected in the`default` mode and the broker.
initial_timestamp                   | i64     | _optional_ | Unix time in milliseconds the initial message of the series was created.
timestamp                           | i64     | _optional_ | Unix time in milliseconds the message was created.
authorization_time                  | i64     | _optional_ | Time spend by an application on authorization related to the message.
cumulative_authorization_time       | i64     | _optional_ | Time spend by an application on authorization related to all messages of the series.
processing_time                     | i64     | _optional_ | Time spend by an application on processing the message.
cumulative_processing_time          | i64     | _optional_ | Time spend by an application on processing all messages of the series.
