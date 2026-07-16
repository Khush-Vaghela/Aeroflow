-- ============================================================
-- PostgreSQL DDL Script — AeroFlow (v2)
-- ============================================================
-- Changelog from v1 (see README.md for full rationale):
--   1. Flight & Flight_Legs: replaced single ambiguous timestamp
--      columns with explicit Scheduled_* / Actual_* pairs, plus
--      STORED generated delay columns (the core ask).
--   2. Removed Source_Airport_ID/Dest_Airport_ID duplication on
--      Flight (already derivable via Flight_Legs -> Route),
--      eliminating a normalization/consistency hazard.
--   3. Split Aircraft into a static dimension table + a
--      time-varying Aircraft_Live_Status table (telemetry was
--      previously mixed into a slow-changing dimension row).
--   4. Added CHECK constraints for enumerated status columns
--      and for time/ordering/value sanity (arrival > departure,
--      fuel >= 0, distance > 0, etc.).
--   5. Added UNIQUE constraints for natural keys (IATA codes)
--      and to prevent duplicate seat assignment on a leg.
--   6. Widened Airline.Email (was VARCHAR(20), too short for
--      real addresses) and added audit timestamp on Booking.
--   7. Added a trigger to keep Current_Fuel_Level from
--      exceeding Total_Fuel_Capacity (cross-table invariant
--      that a CHECK constraint alone cannot express).
-- ============================================================

CREATE SCHEMA AeroFlow;
SET SEARCH_PATH TO AeroFlow;

-- ------------------------------------------------------------
-- 1. AIRLINE
-- ------------------------------------------------------------
CREATE TABLE Airline (
    Airline_ID              INT             PRIMARY KEY,
    Airline_Name            VARCHAR(100)    NOT NULL,
    Country                 VARCHAR(50)     NOT NULL,
    Headquarters            VARCHAR(100)    NOT NULL,
    Email                   VARCHAR(100)    NOT NULL,   -- was VARCHAR(20)
    IATA_Designator_Codes   VARCHAR(10)     NOT NULL,

    UNIQUE (IATA_Designator_Codes)
);

-- ------------------------------------------------------------
-- 2. AIRCRAFT  (static dimension only — telemetry moved out)
-- ------------------------------------------------------------
CREATE TABLE Aircraft (
    Aircraft_ID             INT             PRIMARY KEY,
    Airline_ID              INT             NOT NULL,
    Model                   VARCHAR(50)     NOT NULL,
    Manufacture_Date        DATE            NOT NULL,
    Total_Flight_Hours      INT             NOT NULL DEFAULT 0,
    Total_Flight_Cycle      INT             NOT NULL DEFAULT 0,
    Tot_Eco_Seats           INT             NOT NULL,
    Tot_Bus_Seats           INT             NOT NULL,
    Total_Fuel_Capacity     DECIMAL(10,2)   NOT NULL,

    FOREIGN KEY (Airline_ID) REFERENCES Airline(Airline_ID),
    CHECK (Tot_Eco_Seats >= 0 AND Tot_Bus_Seats >= 0),
    CHECK (Total_Fuel_Capacity > 0),
    CHECK (Total_Flight_Hours >= 0 AND Total_Flight_Cycle >= 0)
);

-- ------------------------------------------------------------
-- 2b. AIRCRAFT_SEAT_MAP — the real seat inventory backing Seat_Number.
--     Without this, nothing stopped a Booking from referencing a seat
--     that doesn't physically exist. fn_booking_capacity_guard (below)
--     now validates against this table instead of just a headcount.
--     Known trade-off: Aircraft.Tot_Eco_Seats/Tot_Bus_Seats and
--     COUNT(*) FROM Aircraft_Seat_Map GROUP BY Seat_Type are now two
--     sources of the same fact. This table is the authoritative one
--     (the trigger trusts it); Tot_Eco_Seats/Tot_Bus_Seats are kept as
--     a fast-reference summary. A consistency trigger between the two
--     would close that gap — noted in the README as a further
--     enhancement rather than added here, to keep scope bounded.
-- ------------------------------------------------------------
CREATE TABLE Aircraft_Seat_Map (
    Aircraft_ID          INT             NOT NULL,
    Seat_Number          VARCHAR(10)     NOT NULL,
    Seat_Type            VARCHAR(20)     NOT NULL,
    Seat_Class_Features  VARCHAR(50),

    PRIMARY KEY (Aircraft_ID, Seat_Number),
    FOREIGN KEY (Aircraft_ID) REFERENCES Aircraft(Aircraft_ID),
    CHECK (Seat_Type IN ('Economy','Business'))
);

-- ------------------------------------------------------------
-- 2c. AIRCRAFT_LIVE_STATUS  (1:1 with Aircraft, changes constantly —
--     kept separate so high-frequency telemetry writes don't
--     churn the aircraft dimension row or its history)
-- ------------------------------------------------------------
CREATE TABLE Aircraft_Live_Status (
    Aircraft_ID             INT             PRIMARY KEY,
    Current_Fuel_Level      DECIMAL(10,2)   NOT NULL,
    Location                VARCHAR(100)    NOT NULL,
    Status_Type             VARCHAR(20)     NOT NULL,
    Current_Speed           DECIMAL(10,2),
    Autopilot_Status        VARCHAR(30),
    Cabin_Pressure_PSI      DECIMAL(5,2),
    Outside_Air_Temperature DECIMAL(5,2),
    Altitude                DECIMAL(9,3),
    Is_In_Aviation          BOOLEAN         NOT NULL DEFAULT FALSE,
    Last_Updated            TIMESTAMP       NOT NULL DEFAULT NOW(),

    FOREIGN KEY (Aircraft_ID) REFERENCES Aircraft(Aircraft_ID),
    CHECK (Current_Fuel_Level >= 0),
    CHECK (Status_Type IN ('Active','Maintenance','Grounded','Retired'))
);

-- Cross-table invariant a CHECK constraint can't express directly:
-- Current_Fuel_Level must never exceed the aircraft's tank capacity.
CREATE OR REPLACE FUNCTION AeroFlow.fn_check_fuel_level()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.Current_Fuel_Level > (
        SELECT Total_Fuel_Capacity FROM AeroFlow.Aircraft WHERE Aircraft_ID = NEW.Aircraft_ID
    ) THEN
        RAISE EXCEPTION 'Current_Fuel_Level (%) exceeds Total_Fuel_Capacity for Aircraft_ID %',
            NEW.Current_Fuel_Level, NEW.Aircraft_ID;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_fuel_level
BEFORE INSERT OR UPDATE ON Aircraft_Live_Status
FOR EACH ROW EXECUTE FUNCTION AeroFlow.fn_check_fuel_level();

-- ------------------------------------------------------------
-- 3. MAINTENANCE
-- ------------------------------------------------------------
CREATE TABLE Maintenance (
    Maintenance_ID      INT             PRIMARY KEY,
    Aircraft_ID         INT             NOT NULL,
    Maintenance_Type    VARCHAR(50)     NOT NULL,
    Technician_Notes    TEXT,
    Maintenance_Status  VARCHAR(30)     NOT NULL,
    Scheduled_Date      DATE            NOT NULL,
    Actual_Start_Date   DATE,
    Completion_Date     DATE,
    Total_Cost          DECIMAL(10,2),

    FOREIGN KEY (Aircraft_ID) REFERENCES Aircraft(Aircraft_ID),
    CHECK (Maintenance_Status IN ('Scheduled','InProgress','Completed','Cancelled')),
    CHECK (Actual_Start_Date IS NULL OR Completion_Date IS NULL OR Completion_Date >= Actual_Start_Date),
    CHECK (Total_Cost IS NULL OR Total_Cost >= 0)
);

-- ------------------------------------------------------------
-- 4. AIRPORT
-- ------------------------------------------------------------
CREATE TABLE Airport (
    Airport_ID      INT             PRIMARY KEY,
    Airport_Name    VARCHAR(100)    NOT NULL,
    City            VARCHAR(50)     NOT NULL,
    State           VARCHAR(50)     NOT NULL,
    Country         VARCHAR(50)     NOT NULL,
    IATA_Code       VARCHAR(10)     NOT NULL,

    UNIQUE (IATA_Code)
);

-- ------------------------------------------------------------
-- 5. RUNWAY
-- ------------------------------------------------------------
CREATE TABLE Runway (
    Airport_ID      INT             NOT NULL,
    Runway_ID       INT             NOT NULL,
    Surface_Type    VARCHAR(30)     NOT NULL,
    Runway_Length   DECIMAL(10,2)   NOT NULL,
    Status          VARCHAR(20)     NOT NULL,

    PRIMARY KEY (Airport_ID, Runway_ID),
    FOREIGN KEY (Airport_ID) REFERENCES Airport(Airport_ID),
    CHECK (Runway_Length > 0),
    CHECK (Status IN ('Open','Closed','Maintenance'))
);

-- ------------------------------------------------------------
-- 6. GATE
-- ------------------------------------------------------------
CREATE TABLE Gate (
    Airport_ID      INT             NOT NULL,
    Gate_No         INT             NOT NULL,
    Gate_Status     VARCHAR(20)     NOT NULL,

    PRIMARY KEY (Airport_ID, Gate_No),
    FOREIGN KEY (Airport_ID) REFERENCES Airport(Airport_ID),
    CHECK (Gate_Status IN ('Available','Occupied','Maintenance'))
);

-- ------------------------------------------------------------
-- 7. ROUTE
-- ------------------------------------------------------------
CREATE TABLE Route (
    Route_ID            INT             PRIMARY KEY,
    Distance             DECIMAL(10,2)   NOT NULL,
    Estimated_Duration   INT             NOT NULL,       -- minutes
    Source_Airport_ID    INT             NOT NULL,
    Dest_Airport_ID      INT             NOT NULL,

    FOREIGN KEY (Source_Airport_ID) REFERENCES Airport(Airport_ID),
    FOREIGN KEY (Dest_Airport_ID)   REFERENCES Airport(Airport_ID),
    CHECK (Source_Airport_ID <> Dest_Airport_ID),
    CHECK (Distance > 0),
    CHECK (Estimated_Duration > 0)
);

-- ------------------------------------------------------------
-- 7b. ROUTE_FARE — base fare catalog per route + seat class.
--     Kept separate from Booking.Fare_Amount deliberately: this is
--     the current listed price used to plan/quote new journeys,
--     while Booking.Fare_Amount is what a specific passenger was
--     actually charged historically. They're allowed to diverge
--     (e.g. after a fare change) without corrupting past records.
-- ------------------------------------------------------------
CREATE TABLE Route_Fare (
    Route_ID    INT             NOT NULL,
    Seat_Type   VARCHAR(20)     NOT NULL,
    Fare_Amount DECIMAL(10,2)   NOT NULL,

    PRIMARY KEY (Route_ID, Seat_Type),
    FOREIGN KEY (Route_ID) REFERENCES Route(Route_ID),
    CHECK (Seat_Type IN ('Economy','Business')),
    CHECK (Fare_Amount > 0)
);

-- ------------------------------------------------------------
-- 8. FLIGHT
--    Source/Dest airport columns removed: they duplicated data
--    already reachable via Flight_Legs -> Route (first leg's
--    source, last leg's destination) and could silently drift
--    out of sync with the actual routing.
-- ------------------------------------------------------------
CREATE TABLE Flight (
    Flight_ID                  INT             PRIMARY KEY,
    Aircraft_ID                INT             NOT NULL,
    Scheduled_Departure_Time   TIMESTAMP       NOT NULL,
    Scheduled_Arrival_Time     TIMESTAMP       NOT NULL,
    Actual_Departure_Time      TIMESTAMP,
    Actual_Arrival_Time        TIMESTAMP,
    Flight_Status              VARCHAR(20)     NOT NULL DEFAULT 'Scheduled',

    Departure_Delay_Minutes INT GENERATED ALWAYS AS (
        CASE WHEN Actual_Departure_Time IS NOT NULL
             THEN CAST(EXTRACT(EPOCH FROM (Actual_Departure_Time - Scheduled_Departure_Time)) / 60 AS INT)
             ELSE NULL END
    ) STORED,

    Arrival_Delay_Minutes INT GENERATED ALWAYS AS (
        CASE WHEN Actual_Arrival_Time IS NOT NULL
             THEN CAST(EXTRACT(EPOCH FROM (Actual_Arrival_Time - Scheduled_Arrival_Time)) / 60 AS INT)
             ELSE NULL END
    ) STORED,

    FOREIGN KEY (Aircraft_ID) REFERENCES Aircraft(Aircraft_ID),
    CHECK (Scheduled_Arrival_Time > Scheduled_Departure_Time),
    CHECK (Actual_Departure_Time IS NULL OR Actual_Arrival_Time IS NULL OR Actual_Arrival_Time > Actual_Departure_Time),
    CHECK (Flight_Status IN ('Scheduled','Boarding','Departed','InAir','Landed','Delayed','Cancelled','Diverted'))
);

-- ------------------------------------------------------------
-- 9. FLIGHT_LEGS
-- ------------------------------------------------------------
CREATE TABLE Flight_Legs (
    Flight_ID               INT           NOT NULL,
    Route_ID                INT           NOT NULL,
    Leg_Sequence_No         INT           NOT NULL,
    Scheduled_Takeoff_Time  TIMESTAMP     NOT NULL,
    Scheduled_Landing_Time  TIMESTAMP     NOT NULL,
    Actual_Takeoff_Time     TIMESTAMP,
    Actual_Landing_Time     TIMESTAMP,
    Leg_Status              VARCHAR(30)   NOT NULL DEFAULT 'Scheduled',

    Takeoff_Delay_Minutes INT GENERATED ALWAYS AS (
        CASE WHEN Actual_Takeoff_Time IS NOT NULL
             THEN CAST(EXTRACT(EPOCH FROM (Actual_Takeoff_Time - Scheduled_Takeoff_Time)) / 60 AS INT)
             ELSE NULL END
    ) STORED,

    Landing_Delay_Minutes INT GENERATED ALWAYS AS (
        CASE WHEN Actual_Landing_Time IS NOT NULL
             THEN CAST(EXTRACT(EPOCH FROM (Actual_Landing_Time - Scheduled_Landing_Time)) / 60 AS INT)
             ELSE NULL END
    ) STORED,

    PRIMARY KEY (Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (Flight_ID) REFERENCES Flight(Flight_ID),
    FOREIGN KEY (Route_ID)  REFERENCES Route(Route_ID),
    CHECK (Scheduled_Landing_Time > Scheduled_Takeoff_Time),
    CHECK (Actual_Takeoff_Time IS NULL OR Actual_Landing_Time IS NULL OR Actual_Landing_Time > Actual_Takeoff_Time),
    CHECK (Leg_Status IN ('Scheduled','Boarding','Departed','InAir','Landed','Delayed','Cancelled','Diverted'))
);

-- ------------------------------------------------------------
-- 10. PILOT
-- ------------------------------------------------------------
CREATE TABLE Pilot (
    Pilot_ID            INT             PRIMARY KEY,
    Name                VARCHAR(100)    NOT NULL,
    License_Number      VARCHAR(50)     NOT NULL,
    Email               VARCHAR(100)    NOT NULL,
    Experience_Level    VARCHAR(30)     NOT NULL,

    UNIQUE (License_Number)
);

-- ------------------------------------------------------------
-- 11. CREW
-- ------------------------------------------------------------
CREATE TABLE Crew (
    Crew_ID                 INT             PRIMARY KEY,
    Name                    VARCHAR(100)    NOT NULL,
    Role                    VARCHAR(50)     NOT NULL,
    Experience              INT             NOT NULL,
    Language_Proficiency    VARCHAR(100)    NOT NULL,

    CHECK (Experience >= 0)
);

-- ------------------------------------------------------------
-- 12. USER
-- ------------------------------------------------------------
CREATE TABLE "User" (
    User_ID     INT             PRIMARY KEY,
    Name        VARCHAR(100)    NOT NULL,
    Email       VARCHAR(100)    NOT NULL,
    Phone       VARCHAR(20)     NOT NULL,
    Address     VARCHAR(200)    NOT NULL,

    UNIQUE (Email)
);

-- ------------------------------------------------------------
-- 12b. RESERVATION
--      One row per purchase transaction (PNR-style). Groups all
--      legs of a multi-leg journey under one User_ID/Booking_Date
--      instead of repeating them on every Booking row. Total fare
--      is intentionally NOT stored here — it's always derivable as
--      SUM(Booking.Fare_Amount) WHERE Reservation_ID = ..., and
--      storing it would just be a redundant value that could drift
--      out of sync (the same normalization issue fixed earlier on
--      Flight's duplicated source/dest columns).
-- ------------------------------------------------------------
CREATE TABLE Reservation (
    Reservation_ID      INT             PRIMARY KEY,
    User_ID              INT             NOT NULL,
    Booking_Date         DATE            NOT NULL,
    Reservation_Status   VARCHAR(20)     NOT NULL DEFAULT 'Active',

    FOREIGN KEY (User_ID) REFERENCES "User"(User_ID),
    CHECK (Reservation_Status IN ('Active','Cancelled'))
);

-- ------------------------------------------------------------
-- 13. BOOKING
--     Seat uniqueness is enforced by a partial unique index below
--     (ux_booking_active_seat), scoped to Confirmed/CheckedIn rows,
--     so a cancelled booking's seat can be reused. Waitlisted rows
--     are managed by the trg_booking_capacity_guard and
--     trg_promote_waitlist triggers (see section 19, end of file).
--     User_ID/Booking_Date moved to Reservation; the old
--     Booking_Sequence_No is dropped (it duplicated Leg_Sequence_No
--     — see README discussion). Fare_Amount added: what this
--     passenger was actually charged for this leg.
-- ------------------------------------------------------------
CREATE TABLE Booking (
    Booking_ID          INT             PRIMARY KEY,
    Reservation_ID       INT             NOT NULL,
    Flight_ID           INT             NOT NULL,
    Route_ID            INT             NOT NULL,
    Leg_Sequence_No     INT             NOT NULL,
    Seat_Type           VARCHAR(20)     NOT NULL,
    Seat_Number         VARCHAR(10),                 -- nullable: Waitlisted bookings hold no seat
    Fare_Amount          DECIMAL(10,2)   NOT NULL,
    Booking_Status       VARCHAR(30)     NOT NULL,
    Created_At          TIMESTAMP       NOT NULL DEFAULT NOW(),

    FOREIGN KEY (Reservation_ID) REFERENCES Reservation(Reservation_ID),
    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    CHECK (Seat_Type IN ('Economy','Business')),
    CHECK (Booking_Status IN ('Confirmed','Waitlisted','Cancelled','CheckedIn','NoShow')),
    CHECK (Booking_Status <> 'Waitlisted' OR Seat_Number IS NULL),
    CHECK (Fare_Amount >= 0),
    UNIQUE (Reservation_ID, Flight_ID, Route_ID, Leg_Sequence_No)  -- can't book the same leg twice on one reservation
);

-- Seat uniqueness only applies to bookings that actually occupy a seat.
-- A Cancelled/NoShow row keeps its historical Seat_Number for the record,
-- but doesn't block that seat from being reassigned to someone else.
CREATE UNIQUE INDEX ux_booking_active_seat
    ON Booking (Flight_ID, Route_ID, Leg_Sequence_No, Seat_Number)
    WHERE Seat_Number IS NOT NULL AND Booking_Status IN ('Confirmed','CheckedIn');

-- ------------------------------------------------------------
-- 14. LUGGAGE
-- ------------------------------------------------------------
CREATE TABLE Luggage (
    Luggage_ID  INT             PRIMARY KEY,
    Booking_ID  INT             NOT NULL,
    Tag_Number  VARCHAR(50)     NOT NULL,
    Weight      DECIMAL(6,2)    NOT NULL,

    FOREIGN KEY (Booking_ID) REFERENCES Booking(Booking_ID),
    CHECK (Weight > 0)
);

-- ------------------------------------------------------------
-- 15. PILOT_ASSIGN
-- ------------------------------------------------------------
CREATE TABLE Pilot_Assign (
    Flight_ID       INT   NOT NULL,
    Route_ID        INT   NOT NULL,
    Leg_Sequence_No INT   NOT NULL,
    Pilot_ID        INT   NOT NULL,

    PRIMARY KEY (Flight_ID, Route_ID, Leg_Sequence_No, Pilot_ID),
    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (Pilot_ID) REFERENCES Pilot(Pilot_ID)
);

-- ------------------------------------------------------------
-- 16. CREW_ASSIGN
-- ------------------------------------------------------------
CREATE TABLE Crew_Assign (
    Flight_ID       INT   NOT NULL,
    Route_ID        INT   NOT NULL,
    Leg_Sequence_No INT   NOT NULL,
    Crew_ID         INT   NOT NULL,

    PRIMARY KEY (Flight_ID, Route_ID, Leg_Sequence_No, Crew_ID),
    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (Crew_ID) REFERENCES Crew(Crew_ID)
);

-- ------------------------------------------------------------
-- 17. USES_RUNWAY
-- ------------------------------------------------------------
CREATE TABLE Uses_Runway (
    Flight_ID       INT             NOT NULL,
    Route_ID        INT             NOT NULL,
    Leg_Sequence_No INT             NOT NULL,
    Airport_ID      INT             NOT NULL,
    Runway_ID       INT             NOT NULL,
    Usage_Type      VARCHAR(30)     NOT NULL,

    PRIMARY KEY (Flight_ID, Route_ID, Leg_Sequence_No, Airport_ID, Runway_ID),
    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (Airport_ID, Runway_ID)
        REFERENCES Runway(Airport_ID, Runway_ID),
    CHECK (Usage_Type IN ('Takeoff','Landing'))
);

-- ------------------------------------------------------------
-- 18. USES_GATE
-- ------------------------------------------------------------
CREATE TABLE Uses_Gate (
    Flight_ID       INT             NOT NULL,
    Route_ID        INT             NOT NULL,
    Leg_Sequence_No INT             NOT NULL,
    Airport_ID      INT             NOT NULL,
    Gate_No         INT             NOT NULL,
    Usage_Type      VARCHAR(30)     NOT NULL,

    PRIMARY KEY (Flight_ID, Route_ID, Leg_Sequence_No, Airport_ID, Gate_No),
    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (Airport_ID, Gate_No)
        REFERENCES Gate(Airport_ID, Gate_No),
    CHECK (Usage_Type IN ('Arrival','Departure'))
);

-- ------------------------------------------------------------
-- 19. WAITLIST MANAGEMENT (two triggers on Booking)
-- ------------------------------------------------------------

-- (a) On INSERT: a Waitlisted booking never holds a real seat (belt-and-
--     braces alongside the CHECK constraint). A 'Confirmed'/'CheckedIn'
--     insert is now validated against the real seat inventory
--     (Aircraft_Seat_Map) instead of just a headcount:
--       - if a Seat_Number is given, it must actually exist on this
--         flight's aircraft and be the right class;
--       - if no Seat_Number is given, the trigger auto-assigns the
--         first free matching seat, or rejects the insert (forcing
--         the caller to use 'Waitlisted' instead) if none remain.
CREATE OR REPLACE FUNCTION AeroFlow.fn_booking_capacity_guard()
RETURNS TRIGGER AS $$
DECLARE
    v_aircraft_id INT;
    v_seat        VARCHAR(10);
BEGIN
    IF NEW.Booking_Status = 'Waitlisted' THEN
        NEW.Seat_Number := NULL;
        RETURN NEW;
    END IF;

    IF NEW.Booking_Status IN ('Confirmed','CheckedIn') THEN
        SELECT f.Aircraft_ID INTO v_aircraft_id FROM Flight f WHERE f.Flight_ID = NEW.Flight_ID;

        IF NEW.Seat_Number IS NOT NULL THEN
            PERFORM 1 FROM Aircraft_Seat_Map sm
                     WHERE sm.Aircraft_ID = v_aircraft_id
                       AND sm.Seat_Number = NEW.Seat_Number
                       AND sm.Seat_Type = NEW.Seat_Type;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Seat % is not a valid % seat on the aircraft operating Flight %',
                    NEW.Seat_Number, NEW.Seat_Type, NEW.Flight_ID;
            END IF;
        ELSE
            SELECT sm.Seat_Number INTO v_seat
            FROM Aircraft_Seat_Map sm
            WHERE sm.Aircraft_ID = v_aircraft_id AND sm.Seat_Type = NEW.Seat_Type
              AND NOT EXISTS (
                  SELECT 1 FROM Booking b
                  WHERE b.Flight_ID = NEW.Flight_ID AND b.Route_ID = NEW.Route_ID
                    AND b.Leg_Sequence_No = NEW.Leg_Sequence_No AND b.Seat_Number = sm.Seat_Number
                    AND b.Booking_Status IN ('Confirmed','CheckedIn')
              )
            ORDER BY sm.Seat_Number
            LIMIT 1;

            IF v_seat IS NULL THEN
                RAISE EXCEPTION 'No % seats left on Flight % leg %/%/% — insert as Waitlisted instead',
                    NEW.Seat_Type, NEW.Flight_ID, NEW.Flight_ID, NEW.Route_ID, NEW.Leg_Sequence_No;
            END IF;

            NEW.Seat_Number := v_seat;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_capacity_guard
BEFORE INSERT ON Booking
FOR EACH ROW EXECUTE FUNCTION AeroFlow.fn_booking_capacity_guard();

-- (b) On UPDATE: when a Confirmed/CheckedIn booking is cancelled, its
--     seat frees up. Promote the oldest matching Waitlisted booking
--     (same flight leg + seat type, FIFO by Created_At) into that seat.
--     SKIP LOCKED keeps this concurrency-safe if two cancellations on
--     the same leg race each other.
CREATE OR REPLACE FUNCTION AeroFlow.fn_promote_waitlist()
RETURNS TRIGGER AS $$
DECLARE
    v_next_booking_id INT;
BEGIN
    IF NEW.Booking_Status = 'Cancelled'
       AND OLD.Booking_Status IN ('Confirmed','CheckedIn')
       AND OLD.Seat_Number IS NOT NULL THEN

        SELECT Booking_ID INTO v_next_booking_id
        FROM Booking
        WHERE Flight_ID = OLD.Flight_ID AND Route_ID = OLD.Route_ID
          AND Leg_Sequence_No = OLD.Leg_Sequence_No AND Seat_Type = OLD.Seat_Type
          AND Booking_Status = 'Waitlisted'
        ORDER BY Created_At ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;

        IF v_next_booking_id IS NOT NULL THEN
            UPDATE Booking
            SET Seat_Number = OLD.Seat_Number, Booking_Status = 'Confirmed'
            WHERE Booking_ID = v_next_booking_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_promote_waitlist
AFTER UPDATE OF Booking_Status ON Booking
FOR EACH ROW EXECUTE FUNCTION AeroFlow.fn_promote_waitlist();

-- ------------------------------------------------------------
-- 20. JOURNEY PLANNING — three stored functions over the Route/
--     Route_Fare graph (Airport = node, Route = directed edge,
--     Route_Fare.Fare_Amount = edge weight). Each picks the
--     algorithm actually suited to what it's answering rather than
--     one generic approach for all three — see README for why.
-- ------------------------------------------------------------

-- (a) fn_all_journeys — every simple path (no repeated airport)
--     from source to destination, up to p_max_stops layovers.
--     Algorithm: DFS via recursive CTE, using the accumulated path
--     array as the visited-set to block cycles — the standard way
--     to enumerate all simple paths in a graph. Genuinely
--     exponential in the worst case; that's inherent to "list every
--     possible journey", not a flaw in the implementation.
CREATE OR REPLACE FUNCTION AeroFlow.fn_all_journeys(
    p_source INT,
    p_dest INT,
    p_seat_type VARCHAR DEFAULT 'Economy',
    p_max_stops INT DEFAULT 4
)
RETURNS TABLE (
    journey_path TEXT,
    num_stops INT,
    total_cost NUMERIC
)
AS $$
WITH RECURSIVE journey AS (
    -- Base case
    SELECT
        r.Dest_Airport_ID AS current_airport,
        ARRAY[r.Source_Airport_ID, r.Dest_Airport_ID] AS path,
        rf.Fare_Amount::NUMERIC AS cost,
        0 AS stops
    FROM Route r
    JOIN Route_Fare rf
        ON rf.Route_ID = r.Route_ID
       AND rf.Seat_Type = p_seat_type
    WHERE r.Source_Airport_ID = p_source

    UNION ALL

    -- Recursive step
    SELECT
        r.Dest_Airport_ID,
        j.path || r.Dest_Airport_ID,
        (j.cost + rf.Fare_Amount)::NUMERIC AS cost,
        j.stops + 1
    FROM journey j
    JOIN Route r
        ON r.Source_Airport_ID = j.current_airport
    JOIN Route_Fare rf
        ON rf.Route_ID = r.Route_ID
       AND rf.Seat_Type = p_seat_type
    WHERE NOT (r.Dest_Airport_ID = ANY(j.path))
      AND j.stops < p_max_stops
)
SELECT
    (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY u.ord)
        FROM unnest(j.path) WITH ORDINALITY AS u(airport_id, ord)
        JOIN Airport a
            ON a.Airport_ID = u.airport_id
    ) AS journey_path,
    j.stops AS num_stops,
    j.cost AS total_cost
FROM journey j
WHERE j.current_airport = p_dest
ORDER BY j.cost;
$$
LANGUAGE SQL
STABLE;

-- (b) fn_cheapest_journey — the single minimum-cost journey.
--     Algorithm: Dijkstra's algorithm (array-based, O(V^2 + E), fine
--     for an airport-network-sized graph), with early exit once the
--     destination is settled. Deliberately NOT "call fn_all_journeys
--     and take MIN()" — that would still pay the exponential
--     enumeration cost for no reason; Dijkstra finds the answer in
--     polynomial time because it never needs to look at most paths.
CREATE OR REPLACE FUNCTION AeroFlow.fn_cheapest_journey(
    p_source INT, p_dest INT,
    p_seat_type VARCHAR DEFAULT 'Economy'
)
RETURNS TABLE(journey_path TEXT, total_cost DECIMAL) AS $$
DECLARE
    v_airports INT[];
    n          INT;
    dist       DECIMAL[];
    pred       INT[];
    visited    BOOLEAN[];
    u_idx      INT;
    v_idx      INT;
    min_dist   DECIMAL;
    min_idx    INT;
    u_airport  INT;
    rec        RECORD;
    path_ids   INT[];
    cur        INT;
BEGIN
    IF p_source = p_dest THEN
        journey_path := (SELECT IATA_Code FROM Airport WHERE Airport_ID = p_source);
        total_cost := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT array_agg(Airport_ID ORDER BY Airport_ID) INTO v_airports FROM Airport;
    n := array_length(v_airports, 1);
    dist    := array_fill(NULL::DECIMAL, ARRAY[n]);
    pred    := array_fill(NULL::INT, ARRAY[n]);
    visited := array_fill(FALSE, ARRAY[n]);
    dist[array_position(v_airports, p_source)] := 0;

    FOR i IN 1..n LOOP
        min_dist := NULL; min_idx := NULL;
        FOR u_idx IN 1..n LOOP
            IF NOT visited[u_idx] AND dist[u_idx] IS NOT NULL
               AND (min_dist IS NULL OR dist[u_idx] < min_dist) THEN
                min_dist := dist[u_idx];
                min_idx  := u_idx;
            END IF;
        END LOOP;

        EXIT WHEN min_idx IS NULL;                 -- remaining nodes unreachable
        visited[min_idx] := TRUE;
        u_airport := v_airports[min_idx];
        EXIT WHEN u_airport = p_dest;               -- destination settled, done

        FOR rec IN
            SELECT r.Dest_Airport_ID AS v, rf.Fare_Amount AS w
            FROM Route r
            JOIN Route_Fare rf ON rf.Route_ID = r.Route_ID AND rf.Seat_Type = p_seat_type
            WHERE r.Source_Airport_ID = u_airport
        LOOP
            v_idx := array_position(v_airports, rec.v);
            IF NOT visited[v_idx]
               AND (dist[v_idx] IS NULL OR dist[min_idx] + rec.w < dist[v_idx]) THEN
                dist[v_idx] := dist[min_idx] + rec.w;
                pred[v_idx] := u_airport;
            END IF;
        END LOOP;
    END LOOP;

    IF dist[array_position(v_airports, p_dest)] IS NULL THEN
        RETURN;   -- no route exists
    END IF;

    path_ids := ARRAY[p_dest];
    cur := p_dest;
    WHILE cur <> p_source LOOP
        cur := pred[array_position(v_airports, cur)];
        path_ids := array_prepend(cur, path_ids);
    END LOOP;

    journey_path := (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY ord)
        FROM unnest(path_ids) WITH ORDINALITY AS u(airport_id, ord)
        JOIN Airport a ON a.Airport_ID = u.airport_id
    );
    total_cost := dist[array_position(v_airports, p_dest)];
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) fn_cheapest_journey_k_stops — minimum-cost journey using at
--     most p_max_stops intermediate stops (i.e. at most
--     p_max_stops + 1 legs).
--     Algorithm: Bellman-Ford restricted to (p_max_stops + 1)
--     relaxation rounds — the classic "cheapest flights within K
--     stops" approach. Plain Dijkstra has no native hop-limit
--     variant (adding one would blow up the state space to
--     node x stops-used); Bellman-Ford naturally bounds path length
--     by the number of relaxation rounds performed. Each round
--     relaxes from a *snapshot* of the previous round's distances
--     (prev_dist), never from values updated in this same round —
--     that's what stops a single round from silently using more
--     than one extra edge.
CREATE OR REPLACE FUNCTION AeroFlow.fn_cheapest_journey_k_stops(
    p_source INT, p_dest INT, p_max_stops INT,
    p_seat_type VARCHAR DEFAULT 'Economy'
)
RETURNS TABLE(journey_path TEXT, num_stops INT, total_cost DECIMAL) AS $$
DECLARE
    v_airports INT[];
    n          INT;
    prev_dist  DECIMAL[];
    curr_dist  DECIMAL[];
    prev_pred  INT[];
    curr_pred  INT[];
    u_idx      INT;
    v_idx      INT;
    rec        RECORD;
    path_ids   INT[];
    cur        INT;
    hop_count  INT;
    dest_idx   INT;
BEGIN
    IF p_source = p_dest THEN
        journey_path := (SELECT IATA_Code FROM Airport WHERE Airport_ID = p_source);
        num_stops := 0;
        total_cost := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT array_agg(Airport_ID ORDER BY Airport_ID) INTO v_airports FROM Airport;
    n := array_length(v_airports, 1);
    prev_dist := array_fill(NULL::DECIMAL, ARRAY[n]);
    prev_pred := array_fill(NULL::INT, ARRAY[n]);
    prev_dist[array_position(v_airports, p_source)] := 0;

    FOR round IN 1..(p_max_stops + 1) LOOP
        curr_dist := prev_dist;
        curr_pred := prev_pred;

        FOR rec IN
            SELECT r.Source_Airport_ID AS u, r.Dest_Airport_ID AS v, rf.Fare_Amount AS w
            FROM Route r
            JOIN Route_Fare rf ON rf.Route_ID = r.Route_ID AND rf.Seat_Type = p_seat_type
        LOOP
            u_idx := array_position(v_airports, rec.u);
            v_idx := array_position(v_airports, rec.v);
            IF prev_dist[u_idx] IS NOT NULL
               AND (curr_dist[v_idx] IS NULL OR prev_dist[u_idx] + rec.w < curr_dist[v_idx]) THEN
                curr_dist[v_idx] := prev_dist[u_idx] + rec.w;
                curr_pred[v_idx] := rec.u;
            END IF;
        END LOOP;

        prev_dist := curr_dist;
        prev_pred := curr_pred;
    END LOOP;

    dest_idx := array_position(v_airports, p_dest);
    IF prev_dist[dest_idx] IS NULL THEN
        RETURN;   -- no route within the stop budget
    END IF;

    path_ids := ARRAY[p_dest];
    cur := p_dest;
    hop_count := 0;
    WHILE cur <> p_source LOOP
        cur := prev_pred[array_position(v_airports, cur)];
        path_ids := array_prepend(cur, path_ids);
        hop_count := hop_count + 1;
    END LOOP;

    journey_path := (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY ord)
        FROM unnest(path_ids) WITH ORDINALITY AS u(airport_id, ord)
        JOIN Airport a ON a.Airport_ID = u.airport_id
    );
    num_stops := hop_count - 1;   -- edges minus 1 = intermediate stops
    total_cost := prev_dist[dest_idx];
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- 21. TRANSACTIONAL RESERVATION CREATION
-- ------------------------------------------------------------
-- Books a Reservation and all of its Booking rows as one atomic unit.
-- p_legs is a JSONB array of objects:
--   {"flight_id":1001,"route_id":1,"leg_sequence_no":1,
--    "seat_type":"Economy","seat_number":"14A","fare_amount":4700.00,
--    "booking_status":"Confirmed"}
-- "seat_number" and "booking_status" are optional — omit seat_number
-- to let trg_booking_capacity_guard auto-assign a free seat; omit
-- booking_status to default to 'Confirmed'.
--
-- Atomicity comes from PL/pgSQL's own semantics, not anything special
-- written here: a PROCEDURE's body runs as part of the caller's
-- transaction (or its own implicit one, if CALL'd at the top level).
-- If any leg's INSERT trips trg_booking_capacity_guard's exception
-- (seat invalid, or the class is full and no Seat_Number was given to
-- auto-assign), the exception propagates out of the procedure and
-- Postgres rolls back everything done so far in this CALL — the
-- Reservation row and any already-inserted Booking rows — so there's
-- no such thing as a half-booked multi-leg itinerary.
CREATE OR REPLACE PROCEDURE AeroFlow.sp_create_reservation(
    p_user_id      INT,
    p_booking_date DATE,
    p_legs         JSONB,
    INOUT p_reservation_id INT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_leg             JSONB;
    v_next_booking_id INT;
BEGIN
    IF p_legs IS NULL OR jsonb_array_length(p_legs) = 0 THEN
        RAISE EXCEPTION 'sp_create_reservation: p_legs must contain at least one leg';
    END IF;

    SELECT COALESCE(MAX(Reservation_ID), 0) + 1 INTO p_reservation_id FROM Reservation;
    INSERT INTO Reservation (Reservation_ID, User_ID, Booking_Date, Reservation_Status)
    VALUES (p_reservation_id, p_user_id, p_booking_date, 'Active');

    FOR v_leg IN SELECT * FROM jsonb_array_elements(p_legs) LOOP
        SELECT COALESCE(MAX(Booking_ID), 0) + 1 INTO v_next_booking_id FROM Booking;

        INSERT INTO Booking
            (Booking_ID, Reservation_ID, Flight_ID, Route_ID, Leg_Sequence_No,
             Seat_Type, Seat_Number, Fare_Amount, Booking_Status)
        VALUES (
            v_next_booking_id,
            p_reservation_id,
            (v_leg->>'flight_id')::INT,
            (v_leg->>'route_id')::INT,
            (v_leg->>'leg_sequence_no')::INT,
            v_leg->>'seat_type',
            v_leg->>'seat_number',                              -- NULL is fine: triggers auto-assign
            (v_leg->>'fare_amount')::DECIMAL,
            COALESCE(v_leg->>'booking_status', 'Confirmed')
        );
        -- trg_booking_capacity_guard fires here on every iteration; a
        -- failure on leg 2 of a 2-leg trip rolls back leg 1's insert
        -- and the Reservation row too, once the exception propagates.
    END LOOP;
END;
$$;

-- ------------------------------------------------------------
-- 22. TIME-AWARE JOURNEY SEARCH (schedule-aware variants)
-- ------------------------------------------------------------
-- Section 20's three functions search the static Route/Route_Fare
-- graph — they answer "does a sequence of routes exist" without
-- checking whether any actual flight instance could make the
-- connection in time. AMD -> DEL -> CCU is a valid *route* even if,
-- on a given day, the DEL -> CCU leg departs before the AMD -> DEL
-- leg lands. These three functions fix that: they traverse actual
-- Flight_Legs rows instead of Route rows, gated by
--   next_leg.Scheduled_Takeoff_Time >=
--       prev_leg.Scheduled_Landing_Time + p_min_connection_minutes
-- Cancelled legs are excluded, and the search only considers legs
-- departing within [p_earliest_departure, p_earliest_departure +
-- p_search_window_hours] — a real search always has a travel date
-- and a bounded planning horizon, not "search all time".
--
-- A key structural fact this design leans on: because every valid
-- connection requires strictly later departure than the previous
-- leg's arrival, the time-expanded graph has NO CYCLES — a path can
-- never return to a state it already passed through in time. That
-- makes it a DAG, and DAG shortest paths can be solved with a single
-- topologically-ordered pass (sorting legs by departure time), which
-- is what functions (b) and (c) below do — genuinely simpler *and*
-- more efficient than rerunning Dijkstra/Bellman-Ford naively, and
-- it sidesteps a real correctness trap: once time enters the picture,
-- "cheapest so far per airport" is no longer well-defined on its own
-- (a costlier-but-earlier arrival can enable a connection a
-- cheaper-but-later arrival would miss), so state has to be indexed
-- by *leg* (a specific flight instance), not by airport.

-- (a) fn_all_journeys_scheduled — every simple, time-feasible
--     itinerary from source to destination. Same DFS-via-recursive-
--     CTE idea as fn_all_journeys, with the connection-time gate
--     added and Flight_Legs/Route_Fare as the edge set.
CREATE OR REPLACE FUNCTION AeroFlow.fn_all_journeys_scheduled(
    p_source INT,
    p_dest INT,
    p_earliest_departure TIMESTAMP,
    p_seat_type VARCHAR DEFAULT 'Economy',
    p_min_connection_minutes INT DEFAULT 45,
    p_max_stops INT DEFAULT 3,
    p_search_window_hours INT DEFAULT 48
)
RETURNS TABLE (
    journey_path TEXT,
    flight_sequence TEXT,
    departure_time TIMESTAMP,
    arrival_time TIMESTAMP,
    num_stops INT,
    total_cost NUMERIC
)
AS $$
WITH RECURSIVE journey AS (

    -- Base case
    SELECT
        r.Dest_Airport_ID AS current_airport,
        ARRAY[r.Source_Airport_ID, r.Dest_Airport_ID] AS path,
        ARRAY[fl.Flight_ID] AS flights,
        rf.Fare_Amount::NUMERIC AS cost,
        0 AS stops,
        fl.Scheduled_Takeoff_Time AS first_departure,
        fl.Scheduled_Landing_Time AS last_landing
    FROM Flight_Legs fl
    JOIN Route r
        ON r.Route_ID = fl.Route_ID
    JOIN Route_Fare rf
        ON rf.Route_ID = fl.Route_ID
       AND rf.Seat_Type = p_seat_type
    WHERE r.Source_Airport_ID = p_source
      AND fl.Leg_Status <> 'Cancelled'
      AND fl.Scheduled_Takeoff_Time >= p_earliest_departure
      AND fl.Scheduled_Takeoff_Time <=
          p_earliest_departure +
          (p_search_window_hours || ' hours')::INTERVAL

    UNION ALL

    -- Recursive step
    SELECT
        r.Dest_Airport_ID,
        j.path || r.Dest_Airport_ID,
        j.flights || fl.Flight_ID,
        (j.cost + rf.Fare_Amount)::NUMERIC AS cost,
        j.stops + 1,
        j.first_departure,
        fl.Scheduled_Landing_Time
    FROM journey j
    JOIN Route r
        ON r.Source_Airport_ID = j.current_airport
    JOIN Flight_Legs fl
        ON fl.Route_ID = r.Route_ID
    JOIN Route_Fare rf
        ON rf.Route_ID = r.Route_ID
       AND rf.Seat_Type = p_seat_type
    WHERE NOT (r.Dest_Airport_ID = ANY(j.path))
      AND j.stops < p_max_stops
      AND fl.Leg_Status <> 'Cancelled'
      AND fl.Scheduled_Takeoff_Time >=
          j.last_landing +
          (p_min_connection_minutes || ' minutes')::INTERVAL
      AND fl.Scheduled_Takeoff_Time <=
          p_earliest_departure +
          (p_search_window_hours || ' hours')::INTERVAL
)

SELECT
    (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY u.ord)
        FROM unnest(j.path) WITH ORDINALITY AS u(airport_id, ord)
        JOIN Airport a
            ON a.Airport_ID = u.airport_id
    ) AS journey_path,

    (
        SELECT string_agg(f::TEXT, ' -> ' ORDER BY u.ord)
        FROM unnest(j.flights) WITH ORDINALITY AS u(f, ord)
    ) AS flight_sequence,

    j.first_departure AS departure_time,
    j.last_landing AS arrival_time,
    j.stops AS num_stops,
    j.cost AS total_cost

FROM journey j
WHERE j.current_airport = p_dest
ORDER BY j.cost ASC;

$$
LANGUAGE SQL
STABLE;

-- (b) fn_cheapest_journey_scheduled — minimum-cost bookable itinerary.
--     Algorithm: single-pass DAG shortest path. Flight_Legs relevant
--     to the search window are pulled into arrays sorted by
--     Scheduled_Takeoff_Time (a valid topological order, since a
--     connection always requires a strictly later departure). For
--     each leg i, dist[i] = fare(i) + the cheaper of (a) 0, if leg i
--     is a valid first hop from p_source, or (b) min(dist[j]) over
--     every earlier leg j whose destination/landing-time legally
--     connects into leg i. Because the array is already
--     topologically ordered, every dist[j] needed is already final
--     by the time leg i is processed — one pass, O(L^2) worst case
--     for L relevant legs, no re-relaxation needed (unlike Bellman-
--     Ford on a general graph).
CREATE OR REPLACE FUNCTION AeroFlow.fn_cheapest_journey_scheduled(
    p_source INT, p_dest INT, p_earliest_departure TIMESTAMP,
    p_seat_type VARCHAR DEFAULT 'Economy',
    p_min_connection_minutes INT DEFAULT 45,
    p_search_window_hours INT DEFAULT 48
)
RETURNS TABLE(journey_path TEXT, flight_sequence TEXT, departure_time TIMESTAMP,
              arrival_time TIMESTAMP, num_stops INT, total_cost DECIMAL) AS $$
DECLARE
    leg_flight  INT[];
    leg_src     INT[];
    leg_dst     INT[];
    leg_takeoff TIMESTAMP[];
    leg_landing TIMESTAMP[];
    leg_fare    DECIMAL[];
    n           INT;
    dist        DECIMAL[];
    pred        INT[];
    i           INT;
    j           INT;
    candidate   DECIMAL;
    best_i      INT;
    path_legs   INT[];
    cur         INT;
BEGIN
    SELECT array_agg(fl.Flight_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(r.Source_Airport_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(r.Dest_Airport_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(fl.Scheduled_Takeoff_Time ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(fl.Scheduled_Landing_Time ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(rf.Fare_Amount ORDER BY fl.Scheduled_Takeoff_Time)
    INTO leg_flight, leg_src, leg_dst, leg_takeoff, leg_landing, leg_fare
    FROM Flight_Legs fl
    JOIN Route r ON r.Route_ID = fl.Route_ID
    JOIN Route_Fare rf ON rf.Route_ID = fl.Route_ID AND rf.Seat_Type = p_seat_type
    WHERE fl.Leg_Status <> 'Cancelled'
      AND fl.Scheduled_Takeoff_Time >= p_earliest_departure
      AND fl.Scheduled_Takeoff_Time <= p_earliest_departure + (p_search_window_hours || ' hours')::INTERVAL;

    n := COALESCE(array_length(leg_flight, 1), 0);
    dist := array_fill(NULL::DECIMAL, ARRAY[n]);
    pred := array_fill(NULL::INT, ARRAY[n]);

    FOR i IN 1..n LOOP
        best_i := NULL;

        IF leg_src[i] = p_source THEN
            dist[i] := leg_fare[i];
        END IF;

        FOR j IN 1..(i-1) LOOP
            IF dist[j] IS NOT NULL
               AND leg_dst[j] = leg_src[i]
               AND leg_takeoff[i] >= leg_landing[j] + (p_min_connection_minutes || ' minutes')::INTERVAL THEN
                candidate := dist[j] + leg_fare[i];
                IF dist[i] IS NULL OR candidate < dist[i] THEN
                    dist[i] := candidate;
                    pred[i] := j;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    -- pick the cheapest leg landing at the destination
    best_i := NULL;
    FOR i IN 1..n LOOP
        IF leg_dst[i] = p_dest AND dist[i] IS NOT NULL
           AND (best_i IS NULL OR dist[i] < dist[best_i]) THEN
            best_i := i;
        END IF;
    END LOOP;

    IF best_i IS NULL THEN
        RETURN;   -- no time-feasible itinerary within the search window
    END IF;

    path_legs := ARRAY[best_i];
    cur := best_i;
    WHILE pred[cur] IS NOT NULL LOOP
        cur := pred[cur];
        path_legs := array_prepend(cur, path_legs);
    END LOOP;

    journey_path := (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY ord)
        FROM (
            SELECT leg_src[path_legs[1]] AS airport_id, 0 AS ord
            UNION ALL
            SELECT leg_dst[l], o FROM unnest(path_legs) WITH ORDINALITY AS u(l, o)
        ) x
        JOIN Airport a ON a.Airport_ID = x.airport_id
    );
    flight_sequence := (SELECT string_agg(leg_flight[l]::TEXT, ' -> ' ORDER BY ord)
                         FROM unnest(path_legs) WITH ORDINALITY AS u(l, ord));
    departure_time := leg_takeoff[path_legs[1]];
    arrival_time    := leg_landing[best_i];
    num_stops       := array_length(path_legs, 1) - 1;
    total_cost      := dist[best_i];
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) fn_cheapest_journey_scheduled_k_stops — cheapest bookable
--     itinerary using at most p_max_stops connections.
--     Algorithm: the same leg-indexed DP as (b), but now indexed by
--     hop count too — Bellman-Ford's round-limited relaxation
--     (prev/curr snapshots, exactly as in the static-graph
--     fn_cheapest_journey_k_stops), just replacing "airport" nodes
--     with "leg" nodes and adding the same time-connection gate used
--     in (b). This is necessary because, exactly as in the static
--     case, the plain cheapest-so-far value at a leg can come from a
--     path with more hops than the budget allows — the round limit
--     is what enforces the stop constraint correctly.
CREATE OR REPLACE FUNCTION AeroFlow.fn_cheapest_journey_scheduled_k_stops(
    p_source INT, p_dest INT, p_earliest_departure TIMESTAMP, p_max_stops INT,
    p_seat_type VARCHAR DEFAULT 'Economy',
    p_min_connection_minutes INT DEFAULT 45,
    p_search_window_hours INT DEFAULT 48
)
RETURNS TABLE(journey_path TEXT, flight_sequence TEXT, departure_time TIMESTAMP,
              arrival_time TIMESTAMP, num_stops INT, total_cost DECIMAL) AS $$
DECLARE
    leg_flight  INT[];
    leg_src     INT[];
    leg_dst     INT[];
    leg_takeoff TIMESTAMP[];
    leg_landing TIMESTAMP[];
    leg_fare    DECIMAL[];
    n           INT;
    prev_dist   DECIMAL[];
    curr_dist   DECIMAL[];
    prev_pred   INT[];
    curr_pred   INT[];
    i           INT;
    j           INT;
    candidate   DECIMAL;
    best_i      INT;
    path_legs   INT[];
    cur         INT;
BEGIN
    SELECT array_agg(fl.Flight_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(r.Source_Airport_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(r.Dest_Airport_ID ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(fl.Scheduled_Takeoff_Time ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(fl.Scheduled_Landing_Time ORDER BY fl.Scheduled_Takeoff_Time),
           array_agg(rf.Fare_Amount ORDER BY fl.Scheduled_Takeoff_Time)
    INTO leg_flight, leg_src, leg_dst, leg_takeoff, leg_landing, leg_fare
    FROM Flight_Legs fl
    JOIN Route r ON r.Route_ID = fl.Route_ID
    JOIN Route_Fare rf ON rf.Route_ID = fl.Route_ID AND rf.Seat_Type = p_seat_type
    WHERE fl.Leg_Status <> 'Cancelled'
      AND fl.Scheduled_Takeoff_Time >= p_earliest_departure
      AND fl.Scheduled_Takeoff_Time <= p_earliest_departure + (p_search_window_hours || ' hours')::INTERVAL;

    n := COALESCE(array_length(leg_flight, 1), 0);
    prev_dist := array_fill(NULL::DECIMAL, ARRAY[n]);
    prev_pred := array_fill(NULL::INT, ARRAY[n]);

    FOR round IN 1..(p_max_stops + 1) LOOP
        curr_dist := prev_dist;
        curr_pred := prev_pred;

        FOR i IN 1..n LOOP
            IF round = 1 AND leg_src[i] = p_source THEN
                IF curr_dist[i] IS NULL OR leg_fare[i] < curr_dist[i] THEN
                    curr_dist[i] := leg_fare[i];
                    curr_pred[i] := NULL;
                END IF;
            END IF;

            FOR j IN 1..n LOOP
                IF prev_dist[j] IS NOT NULL AND j <> i
                   AND leg_dst[j] = leg_src[i]
                   AND leg_takeoff[i] >= leg_landing[j] + (p_min_connection_minutes || ' minutes')::INTERVAL THEN
                    candidate := prev_dist[j] + leg_fare[i];
                    IF curr_dist[i] IS NULL OR candidate < curr_dist[i] THEN
                        curr_dist[i] := candidate;
                        curr_pred[i] := j;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;

        prev_dist := curr_dist;
        prev_pred := curr_pred;
    END LOOP;

    best_i := NULL;
    FOR i IN 1..n LOOP
        IF leg_dst[i] = p_dest AND prev_dist[i] IS NOT NULL
           AND (best_i IS NULL OR prev_dist[i] < prev_dist[best_i]) THEN
            best_i := i;
        END IF;
    END LOOP;

    IF best_i IS NULL THEN
        RETURN;   -- no time-feasible itinerary within the stop budget/search window
    END IF;

    path_legs := ARRAY[best_i];
    cur := best_i;
    WHILE prev_pred[cur] IS NOT NULL LOOP
        cur := prev_pred[cur];
        path_legs := array_prepend(cur, path_legs);
    END LOOP;

    journey_path := (
        SELECT string_agg(a.IATA_Code, ' -> ' ORDER BY ord)
        FROM (
            SELECT leg_src[path_legs[1]] AS airport_id, 0 AS ord
            UNION ALL
            SELECT leg_dst[l], o FROM unnest(path_legs) WITH ORDINALITY AS u(l, o)
        ) x
        JOIN Airport a ON a.Airport_ID = x.airport_id
    );
    flight_sequence := (SELECT string_agg(leg_flight[l]::TEXT, ' -> ' ORDER BY ord)
                         FROM unnest(path_legs) WITH ORDINALITY AS u(l, ord));
    departure_time := leg_takeoff[path_legs[1]];
    arrival_time    := leg_landing[best_i];
    num_stops       := array_length(path_legs, 1) - 1;
    total_cost      := prev_dist[best_i];
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;
