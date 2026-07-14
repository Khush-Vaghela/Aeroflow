# AeroFlow — Airline Operations Database

**Purpose.** A relational database modeling air operations —
fleet, maintenance, airport infrastructure, routing, multi-leg flights,
crew/pilot scheduling, and passenger booking.

**Architecture.** A normalized PostgreSQL schema of 19 tables (18 operational
+ 1 telemetry table) with composite keys for per-leg operations, foreign keys
tying every subsystem together, `CHECK` constraints on all enumerated status
columns, and a trigger enforcing a cross-table fuel invariant.

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
```sql
SELECT ac.Tot_Eco_Seats - COUNT(*) FILTER (WHERE b.Seat_Type = 'Economy' AND b.Booking_Status <> 'Cancelled') AS eco_left,
       ac.Tot_Bus_Seats - COUNT(*) FILTER (WHERE b.Seat_Type = 'Business' AND b.Booking_Status <> 'Cancelled') AS bus_left
FROM Flight_Legs fl
JOIN Flight f ON f.Flight_ID = fl.Flight_ID
JOIN Aircraft ac ON ac.Aircraft_ID = f.Aircraft_ID
LEFT JOIN Booking b ON b.Flight_ID = fl.Flight_ID AND b.Route_ID = fl.Route_ID AND b.Leg_Sequence_No = fl.Leg_Sequence_No
WHERE fl.Flight_ID = :flight_id AND fl.Route_ID = :route_id AND fl.Leg_Sequence_No = :leg_no
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
```sql
SELECT g.Gate_No, COUNT(*) AS uses
FROM Uses_Gate ug
JOIN Gate g ON g.Airport_ID = ug.Airport_ID AND g.Gate_No = ug.Gate_No
WHERE ug.Airport_ID = :airport_id
GROUP BY g.Gate_No
ORDER BY uses DESC;
```

**Pilots double-booked on overlapping legs (data-quality audit)**
```sql
SELECT pa1.Pilot_ID, fl1.Flight_ID, fl2.Flight_ID
FROM Pilot_Assign pa1
JOIN Pilot_Assign pa2 ON pa1.Pilot_ID = pa2.Pilot_ID AND pa1.Flight_ID < pa2.Flight_ID
JOIN Flight_Legs fl1 ON fl1.Flight_ID = pa1.Flight_ID AND fl1.Route_ID = pa1.Route_ID AND fl1.Leg_Sequence_No = pa1.Leg_Sequence_No
JOIN Flight_Legs fl2 ON fl2.Flight_ID = pa2.Flight_ID AND fl2.Route_ID = pa2.Route_ID AND fl2.Leg_Sequence_No = pa2.Leg_Sequence_No
WHERE fl1.Scheduled_Takeoff_Time < fl2.Scheduled_Landing_Time
  AND fl2.Scheduled_Takeoff_Time < fl1.Scheduled_Landing_Time;
```

## Possible future extensions
- Partial unique index on `Booking` (active statuses only) instead of a plain
  `UNIQUE` constraint, to allow seat re-sale after cancellation.
- Historical table for `Aircraft_Live_Status` (currently 1:1 current-state
  only; a time-series table would enable full telemetry replay).
- `Created_At`/`Updated_At` audit columns on the remaining mutable tables
  (`Maintenance`, `Aircraft_Live_Status` already has `Last_Updated`).
