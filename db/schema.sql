-- Skimo chip-timing schema sketch (Postgres flavored).
-- Core idea: people, chips and divisions are reusable; an event binds them
-- together through event_divisions and event_participants; timing data is
-- stored twice, once raw (chip_reads) and once resolved (results).

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

-- A division is a category racers compete in (e.g. Race, Rec, Heavy Metal,
-- Youth). It is global so it can be reused across events and reported on.
CREATE TABLE divisions (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL UNIQUE,
    description text,
    sort_order  integer NOT NULL DEFAULT 0
);

CREATE TABLE users (
    id                  bigserial PRIMARY KEY,
    first_name          text NOT NULL,
    last_name           text NOT NULL,
    email               text UNIQUE,
    birth_year          integer,
    gender              text,                      -- optional, if divisions depend on it
    default_division_id bigint REFERENCES divisions(id),
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- A physical timing chip. Kept separate from users because chips get
-- replaced, lent out and reassigned; the history matters when debugging
-- a bad read. At most one *active* assignment per chip at a time.
CREATE TABLE chips (
    chip_id        text PRIMARY KEY,                -- the id the reader reports
    user_id        bigint REFERENCES users(id),
    assigned_at    timestamptz,
    unassigned_at  timestamptz,                     -- NULL = currently assigned
    notes          text
);

CREATE INDEX chips_active_user_idx ON chips (user_id) WHERE unassigned_at IS NULL;

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

CREATE TABLE events (
    id            bigserial PRIMARY KEY,
    name          text NOT NULL,
    event_date    date NOT NULL,
    location      text,
    description   text,
    course_notes  text,
    distance_m    integer,
    vertical_m    integer,
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'open', 'closed', 'finished', 'cancelled')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Which divisions an event offers. Carries the per-event start time so that
-- wave starts work: elapsed = finish_at - start_at for that division.
CREATE TABLE event_divisions (
    event_id    bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    division_id bigint NOT NULL REFERENCES divisions(id),
    start_at    timestamptz,                        -- NULL until the gun goes
    PRIMARY KEY (event_id, division_id)
);

-- A user's registration for one event. This is where "a user can change
-- their division for an event" lives: division_id here overrides
-- users.default_division_id, and must be one the event actually offers.
CREATE TABLE event_participants (
    id            bigserial PRIMARY KEY,
    event_id      bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id       bigint NOT NULL REFERENCES users(id),
    division_id   bigint NOT NULL REFERENCES divisions(id),
    bib_number    integer,
    chip_id       text REFERENCES chips(chip_id),   -- optional per-event override (rental chips)
    registered_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, user_id),
    UNIQUE (event_id, bib_number),
    UNIQUE (event_id, chip_id),
    FOREIGN KEY (event_id, division_id) REFERENCES event_divisions(event_id, division_id)
);

-- ---------------------------------------------------------------------------
-- Timing
-- ---------------------------------------------------------------------------

-- Every read the hardware reports, untouched. Readers fire multiple times per
-- crossing and sometimes see unknown chips, so this is an append-only log
-- that results are derived from, never edited by hand.
CREATE TABLE chip_reads (
    id         bigserial PRIMARY KEY,
    event_id   bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    chip_id    text NOT NULL,                       -- deliberately no FK: unknown chips happen
    reader_id  text,                                -- which antenna/box, if more than one
    read_at    timestamptz NOT NULL,
    raw        jsonb                                -- whatever else the reader sent
);

CREATE INDEX chip_reads_event_time_idx ON chip_reads (event_id, read_at);
CREATE INDEX chip_reads_event_chip_idx ON chip_reads (event_id, chip_id);

-- The resolved result: one row per participant per event. finish_at is the
-- chosen crossing (first read after the division start, after de-duping).
-- Places are not stored; they are computed from finish/elapsed with window
-- functions so a correction never leaves stale ranks behind.
CREATE TABLE results (
    participant_id bigint PRIMARY KEY REFERENCES event_participants(id) ON DELETE CASCADE,
    event_id       bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    finish_at      timestamptz,
    elapsed        interval,                        -- finish_at - event_divisions.start_at
    status         text NOT NULL DEFAULT 'finished'
                   CHECK (status IN ('finished', 'dnf', 'dns', 'dsq')),
    chip_read_id   bigint REFERENCES chip_reads(id),  -- provenance for the finish
    note           text,                            -- why a time was adjusted, etc.
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX results_event_elapsed_idx ON results (event_id, elapsed);

-- ---------------------------------------------------------------------------
-- Ranking (overall and by division) as a view
-- ---------------------------------------------------------------------------

CREATE VIEW event_standings AS
SELECT
    r.event_id,
    ep.division_id,
    ep.user_id,
    u.first_name,
    u.last_name,
    ep.bib_number,
    r.status,
    r.finish_at,
    r.elapsed,
    RANK() OVER (PARTITION BY r.event_id
                 ORDER BY (r.status <> 'finished'), r.elapsed)                 AS overall_place,
    RANK() OVER (PARTITION BY r.event_id, ep.division_id
                 ORDER BY (r.status <> 'finished'), r.elapsed)                 AS division_place
FROM results r
JOIN event_participants ep ON ep.id = r.participant_id
JOIN users u               ON u.id = ep.user_id;
