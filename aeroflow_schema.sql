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
-- 2b. AIRCRAFT_LIVE_STATUS  (1:1 with Aircraft, changes constantly —
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
-- 13. BOOKING
--     Seat uniqueness is enforced by a partial unique index below
--     (ux_booking_active_seat), scoped to Confirmed/CheckedIn rows,
--     so a cancelled booking's seat can be reused. Waitlisted rows
--     are managed by the trg_booking_capacity_guard and
--     trg_promote_waitlist triggers (see section 19, end of file).
-- ------------------------------------------------------------
CREATE TABLE Booking (
    Booking_ID          INT             PRIMARY KEY,
    Flight_ID           INT             NOT NULL,
    Route_ID            INT             NOT NULL,
    Leg_Sequence_No     INT             NOT NULL,
    User_ID             INT             NOT NULL,
    Seat_Type           VARCHAR(20)     NOT NULL,
    Seat_Number         VARCHAR(10),                 -- nullable: Waitlisted bookings hold no seat
    Booking_Date        DATE            NOT NULL,
    Booking_Status       VARCHAR(30)     NOT NULL,
    Booking_Sequence_No INT             NOT NULL,
    Created_At          TIMESTAMP       NOT NULL DEFAULT NOW(),

    FOREIGN KEY (Flight_ID, Route_ID, Leg_Sequence_No)
        REFERENCES Flight_Legs(Flight_ID, Route_ID, Leg_Sequence_No),
    FOREIGN KEY (User_ID) REFERENCES "User"(User_ID),
    CHECK (Seat_Type IN ('Economy','Business')),
    CHECK (Booking_Status IN ('Confirmed','Waitlisted','Cancelled','CheckedIn','NoShow')),
    CHECK (Booking_Status <> 'Waitlisted' OR Seat_Number IS NULL)
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
--     braces alongside the CHECK constraint), and a direct 'Confirmed'
--     insert is rejected once the leg's seat class is already full —
--     the caller must insert it as 'Waitlisted' instead.
CREATE OR REPLACE FUNCTION AeroFlow.fn_booking_capacity_guard()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INT;
    v_taken    INT;
BEGIN
    IF NEW.Booking_Status = 'Waitlisted' THEN
        NEW.Seat_Number := NULL;
        RETURN NEW;
    END IF;

    IF NEW.Booking_Status IN ('Confirmed','CheckedIn') THEN
        SELECT CASE WHEN NEW.Seat_Type = 'Economy' THEN ac.Tot_Eco_Seats ELSE ac.Tot_Bus_Seats END
          INTO v_capacity
        FROM Flight f JOIN Aircraft ac ON ac.Aircraft_ID = f.Aircraft_ID
        WHERE f.Flight_ID = NEW.Flight_ID;

        SELECT COUNT(*) INTO v_taken
        FROM Booking
        WHERE Flight_ID = NEW.Flight_ID AND Route_ID = NEW.Route_ID
          AND Leg_Sequence_No = NEW.Leg_Sequence_No AND Seat_Type = NEW.Seat_Type
          AND Booking_Status IN ('Confirmed','CheckedIn');

        IF v_capacity IS NOT NULL AND v_taken >= v_capacity THEN
            RAISE EXCEPTION 'No % seats left on Flight % leg %/%/% — insert as Waitlisted instead',
                NEW.Seat_Type, NEW.Flight_ID, NEW.Flight_ID, NEW.Route_ID, NEW.Leg_Sequence_No;
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
