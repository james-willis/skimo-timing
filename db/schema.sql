-- Skimo chip-timing schema sketch (SQLite).
-- Core idea: people, chips and divisions are reusable; an event binds them
-- together through event_divisions and event_participants; timing data is
-- stored twice, once raw (chip_reads) and once resolved (results).
--
-- Conventions:
--   * Every timestamp is INTEGER milliseconds since the Unix epoch (UTC).
--     Readers report ms, elapsed arithmetic is plain subtraction, and
--     ordering is exact. Format for display with datetime(ms/1000,'unixepoch').
--   * Dates with no time of day are TEXT 'YYYY-MM-DD'.
--   * Run `PRAGMA foreign_keys = ON;` on every connection; SQLite does not
--     enforce foreign keys unless asked.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

-- A division is a category racers compete in (e.g. Race, Rec, Heavy Metal,
-- Youth). It is global so it can be reused across events and reported on.
CREATE TABLE divisions (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE users (
    id                  INTEGER PRIMARY KEY,
    first_name          TEXT NOT NULL,
    last_name           TEXT NOT NULL,
    email               TEXT UNIQUE,
    default_division_id INTEGER REFERENCES divisions(id),   -- self-selected; divisions do not depend on age or gender
    created_at          INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
);

-- A physical timing chip. People keep one chip for life (often the same one
-- they use for other racing), but chips get lost or replaced, so the
-- assignment is a row with a window rather than a column on users. A chip
-- has at most one owner at a time, and a user has at most one *active* chip,
-- so a read resolves to exactly one person. To replace a chip: set
-- unassigned_at on the old row and insert a new one.
CREATE TABLE chips (
    chip_id        TEXT PRIMARY KEY,                -- the id the reader reports
    user_id        INTEGER REFERENCES users(id),
    assigned_at    INTEGER,
    unassigned_at  INTEGER,                         -- NULL = currently assigned
    notes          TEXT                             -- 'lost 2026-01', 'from cx', ...
);

CREATE UNIQUE INDEX chips_one_active_per_user_idx ON chips (user_id) WHERE unassigned_at IS NULL;

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

CREATE TABLE events (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL,
    event_date    TEXT NOT NULL,                    -- 'YYYY-MM-DD'
    location      TEXT,
    description   TEXT,
    course_notes  TEXT,
    distance_m    INTEGER,
    vertical_m    INTEGER,
    status        TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'open', 'closed', 'finished', 'cancelled')),
    created_at    INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
);

-- Which divisions an event offers. Carries the per-event start time so that
-- wave starts work: elapsed_ms = finish_at - start_at for that division.
CREATE TABLE event_divisions (
    event_id    INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    division_id INTEGER NOT NULL REFERENCES divisions(id),
    start_at    INTEGER,                            -- NULL until the gun goes
    PRIMARY KEY (event_id, division_id)
);

-- A user's registration for one event. This is where "a user can change
-- their division for an event" lives: division_id here overrides
-- users.default_division_id, and must be one the event actually offers.
CREATE TABLE event_participants (
    id            INTEGER PRIMARY KEY,
    event_id      INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id       INTEGER NOT NULL REFERENCES users(id),
    division_id   INTEGER NOT NULL REFERENCES divisions(id),
    bib_number    INTEGER,
    registered_at INTEGER NOT NULL DEFAULT (unixepoch() * 1000),
    UNIQUE (event_id, user_id),
    UNIQUE (event_id, bib_number),
    FOREIGN KEY (event_id, division_id) REFERENCES event_divisions(event_id, division_id)
);

-- ---------------------------------------------------------------------------
-- Timing
-- ---------------------------------------------------------------------------

-- Every read the hardware reports, untouched. Readers fire multiple times per
-- crossing and sometimes see unknown chips, so this is an append-only log
-- that results are derived from, never edited by hand.
CREATE TABLE chip_reads (
    id         INTEGER PRIMARY KEY,
    event_id   INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    chip_id    TEXT NOT NULL,                       -- deliberately no FK: unknown chips happen
    reader_id  TEXT,                                -- which antenna/box, if more than one
    read_at    INTEGER NOT NULL,
    raw        TEXT                                 -- JSON: whatever else the reader sent
);

CREATE INDEX chip_reads_event_time_idx ON chip_reads (event_id, read_at);
CREATE INDEX chip_reads_event_chip_idx ON chip_reads (event_id, chip_id);

-- The resolved result: one row per participant per event. Finish time only,
-- no splits or laps. finish_at is the chosen crossing: the first read of the
-- user's active chip after the division start.
-- Places are not stored; they are computed from elapsed with window
-- functions so a correction never leaves stale ranks behind.
CREATE TABLE results (
    participant_id INTEGER PRIMARY KEY REFERENCES event_participants(id) ON DELETE CASCADE,
    event_id       INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    finish_at      INTEGER,
    elapsed_ms     INTEGER,                         -- finish_at - event_divisions.start_at
    status         TEXT NOT NULL DEFAULT 'finished'
                   CHECK (status IN ('finished', 'dnf', 'dns', 'dsq')),
    chip_read_id   INTEGER REFERENCES chip_reads(id),  -- provenance for the finish
    note           TEXT,                            -- why a time was adjusted, etc.
    updated_at     INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
);

CREATE INDEX results_event_elapsed_idx ON results (event_id, elapsed_ms);

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
    r.elapsed_ms,
    -- 'H:MM:SS.mmm' for display
    printf('%d:%02d:%02d.%03d',
           r.elapsed_ms / 3600000,
           (r.elapsed_ms / 60000) % 60,
           (r.elapsed_ms / 1000) % 60,
           r.elapsed_ms % 1000)                                              AS elapsed,
    RANK() OVER (PARTITION BY r.event_id
                 ORDER BY (r.status <> 'finished'), r.elapsed_ms)              AS overall_place,
    RANK() OVER (PARTITION BY r.event_id, ep.division_id
                 ORDER BY (r.status <> 'finished'), r.elapsed_ms)              AS division_place
FROM results r
JOIN event_participants ep ON ep.id = r.participant_id
JOIN users u               ON u.id = ep.user_id;
