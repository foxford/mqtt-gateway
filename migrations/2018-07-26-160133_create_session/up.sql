create table session (
    id uuid default gen_random_uuid(),

    broker_session_id uuid not null,
    agent_id agent_id not null,
    time tstzrange not null,

    exclude using gist (((agent_id).account_id) with =, ((agent_id).label) with =, time with &&),
    foreign key (broker_session_id) references session (id) on delete cascade,
    primary key (id)
);