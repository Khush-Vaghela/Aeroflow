# AeroFlow — Airline Operations Database

**Purpose.** A relational database modeling airline operations —
fleet, maintenance, airport infrastructure, routing, multi-leg flights,
crew/pilot scheduling, and passenger booking.

**Architecture.** A normalized PostgreSQL schema of 19 tables with composite keys for per-leg operations, foreign keys
tying every subsystem together, `CHECK` constraints on all enumerated status
columns, and three triggers enforcing invariants a `CHECK` constraint can't
express alone (a cross-table fuel-capacity rule, and automatic waitlist
capacity-guarding/promotion on `Booking`).

**Features.** Automatic delay computation via generated columns, a fully
seeded sample dataset, and an ER diagram for quick onboarding.

## Project files
- `aeroflow_schema_v2.sql` — table definitions, constraints, trigger
- `aeroflow_insert_data_v2.sql` — sample dataset (10 airlines, 20 aircraft,
  15 flights / 25 legs, 30 bookings, and more) conformed to the schema
- `aeroflow_er_diagram.mermaid` — entity-relationship diagram
- `README.md` — this file

## ER diagram

See `aeroflow_er_diagram.mermaid` — renders natively in GitHub READMEs
(` ```mermaid ` code block) or the Mermaid Live Editor.

## Entity overview

- **Fleet**: `Airline` → `Aircraft` → `Aircraft_Live_Status`, `Maintenance`
- **Infrastructure**: `Airport` → `Runway`, `Gate`
- **Network**: `Route` (airport pairs) → `Flight_Legs` (route + sequence per
  flight) → `Flight`
- **Crew**: `Pilot`, `Crew` assigned per-leg via `Pilot_Assign`, `Crew_Assign`
- **Passengers**: `User` → `Booking` (tied to a specific leg + seat) → `Luggage`
- **Ground ops**: `Uses_Runway`, `Uses_Gate` (per-leg, per-airport usage)

## Example queries this schema answers directly

Seed data dates are computed relative to `CURRENT_DATE`/`CURRENT_TIMESTAMP`
(see `aeroflow_insert_data_v2.sql`), not hardcoded — so the queries below
return rows regardless of when you load the data. Flight 1013 is deliberately
seeded as currently `InAir` (departed ~2 hours before you run the script).

**Flights delayed more than 30 minutes on departure, most recent first**
```sql
SELECT Flight_ID, Scheduled_Departure_Time, Actual_Departure_Time, Departure_Delay_Minutes
FROM Flight
WHERE Departure_Delay_Minutes > 30
ORDER BY Scheduled_Departure_Time DESC;
```

**On-time departure rate per airline**
```sql
SELECT a.Airline_Name,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.Departure_Delay_Minutes <= 15) / COUNT(*), 1) AS pct_on_time
FROM Flight f
JOIN Aircraft ac ON ac.Aircraft_ID = f.Aircraft_ID
JOIN Airline a ON a.Airline_ID = ac.Airline_ID
WHERE f.Actual_Departure_Time IS NOT NULL
GROUP BY a.Airline_Name
ORDER BY pct_on_time DESC;
```

**Derive each flight's overall source/dest airport (post-normalization)**
```sql
SELECT f.Flight_ID,
       first_leg.Source_Airport_ID,
       last_leg.Dest_Airport_ID
FROM Flight f
JOIN LATERAL (
    SELECT r.Source_Airport_ID
    FROM Flight_Legs fl JOIN Route r ON r.Route_ID = fl.Route_ID
    WHERE fl.Flight_ID = f.Flight_ID ORDER BY fl.Leg_Sequence_No ASC LIMIT 1
) first_leg ON true
JOIN LATERAL (
    SELECT r.Dest_Airport_ID
    FROM Flight_Legs fl JOIN Route r ON r.Route_ID = fl.Route_ID
    WHERE fl.Flight_ID = f.Flight_ID ORDER BY fl.Leg_Sequence_No DESC LIMIT 1
) last_leg ON true;
```

**Aircraft utilization: total flight hours flown in the last 30 days**
```sql
SELECT ac.Aircraft_ID, ac.Model,
       SUM(EXTRACT(EPOCH FROM (fl.Actual_Landing_Time - fl.Actual_Takeoff_Time)) / 3600) AS hours_flown
FROM Aircraft ac
JOIN Flight f ON f.Aircraft_ID = ac.Aircraft_ID
JOIN Flight_Legs fl ON fl.Flight_ID = f.Flight_ID
WHERE fl.Actual_Takeoff_Time >= NOW() - INTERVAL '30 days'
GROUP BY ac.Aircraft_ID, ac.Model
ORDER BY hours_flown DESC;
```

**Available seats remaining on a given leg**
(example values below are Flight 1001's first leg, AMD→BOM)
```sql
SELECT ac.Tot_Eco_Seats - COUNT(*) FILTER (WHERE b.Seat_Type = 'Economy' AND b.Booking_Status <> 'Cancelled') AS eco_left,
       ac.Tot_Bus_Seats - COUNT(*) FILTER (WHERE b.Seat_Type = 'Business' AND b.Booking_Status <> 'Cancelled') AS bus_left
FROM Flight_Legs fl
JOIN Flight f ON f.Flight_ID = fl.Flight_ID
JOIN Aircraft ac ON ac.Aircraft_ID = f.Aircraft_ID
LEFT JOIN Booking b ON b.Flight_ID = fl.Flight_ID AND b.Route_ID = fl.Route_ID AND b.Leg_Sequence_No = fl.Leg_Sequence_No
WHERE fl.Flight_ID = 1001 AND fl.Route_ID = 1 AND fl.Leg_Sequence_No = 1
GROUP BY ac.Tot_Eco_Seats, ac.Tot_Bus_Seats;
```

**Maintenance cost by aircraft and maintenance type**
```sql
SELECT Aircraft_ID, Maintenance_Type, COUNT(*) AS jobs, SUM(Total_Cost) AS total_spent
FROM Maintenance
WHERE Maintenance_Status = 'Completed'
GROUP BY Aircraft_ID, Maintenance_Type
ORDER BY total_spent DESC;
```

**Busiest gates at an airport by usage count**
(example value below is Airport 2, Mumbai/BOM)
```sql
SELECT g.Gate_No, COUNT(*) AS uses
FROM Uses_Gate ug
JOIN Gate g ON g.Airport_ID = ug.Airport_ID AND g.Gate_No = ug.Gate_No
WHERE ug.Airport_ID = 2
GROUP BY g.Gate_No
ORDER BY uses DESC;
```

**Pilots double-booked on overlapping legs (data-quality audit)**
(the seed data deliberately includes one conflict — Pilot 203 on both
Flight 1002 and Flight 1006 — so this returns a row out of the box; on
clean data it should return none)
```sql
SELECT pa1.Pilot_ID, fl1.Flight_ID, fl2.Flight_ID
FROM Pilot_Assign pa1
JOIN Pilot_Assign pa2 ON pa1.Pilot_ID = pa2.Pilot_ID AND pa1.Flight_ID < pa2.Flight_ID
JOIN Flight_Legs fl1 ON fl1.Flight_ID = pa1.Flight_ID AND fl1.Route_ID = pa1.Route_ID AND fl1.Leg_Sequence_No = pa1.Leg_Sequence_No
JOIN Flight_Legs fl2 ON fl2.Flight_ID = pa2.Flight_ID AND fl2.Route_ID = pa2.Route_ID AND fl2.Leg_Sequence_No = pa2.Leg_Sequence_No
WHERE fl1.Scheduled_Takeoff_Time < fl2.Scheduled_Landing_Time
  AND fl2.Scheduled_Takeoff_Time < fl1.Scheduled_Landing_Time;
```

## Testing the waitlist trigger

The seed data pairs Booking 510 (`Confirmed`, seat `30E`, Flight 1007) with
Booking 530 (`Waitlisted`, same flight/leg/seat type). Cancel 510 and watch
530 get promoted automatically:

```sql
UPDATE Booking SET Booking_Status = 'Cancelled' WHERE Booking_ID = 510;

SELECT Booking_ID, Seat_Number, Booking_Status FROM Booking WHERE Booking_ID IN (510, 530);
-- 510 -> Cancelled, Seat_Number still '30E' (kept for the record)
-- 530 -> Confirmed, Seat_Number now '30E'
```

To see the capacity guard reject an over-capacity direct booking, try
inserting a `'Confirmed'` row for a leg/seat-type that's already full — it
will raise an exception telling you to insert it as `'Waitlisted'` instead.

## Possible future extensions
- Historical table for `Aircraft_Live_Status` (currently 1:1 current-state
  only; a time-series table would enable full telemetry replay).
- `Created_At`/`Updated_At` audit columns on the remaining mutable tables
  (`Maintenance`, `Aircraft_Live_Status` already has `Last_Updated`).
- The capacity guard currently reads seat totals once per insert; under
  heavy concurrent booking you'd want `SELECT ... FOR UPDATE` on the
  Aircraft row (or an advisory lock) to close a narrow race window between
  the count check and the insert.
