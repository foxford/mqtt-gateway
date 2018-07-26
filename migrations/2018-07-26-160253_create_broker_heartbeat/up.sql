create table broker_heartbeat (
    broker_id agent_id,
    token bytea not null,
    modified_at timestamptz not null,

    primary key (broker_id)
);