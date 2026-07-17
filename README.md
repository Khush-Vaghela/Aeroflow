# AeroFlow — Airline Operations Database

**Purpose.** A relational database modeling airline operations —
fleet, maintenance, airport infrastructure, routing, multi-leg flights,
crew/pilot scheduling, and passenger booking/fares, with flight-delay tracking and time-aware journey
planning against the actual flight schedule.

**Architecture.** A normalized PostgreSQL schema of 22 tables with composite keys for per-leg operations,
foreign keys tying every subsystem together, `CHECK` constraints on all
enumerated status columns, three triggers enforcing invariants a `CHECK`
constraint can't express alone (a cross-table fuel-capacity rule, and
automatic seat-map-backed waitlist capacity-guarding/promotion on
`Booking`), a stored procedure wrapping multi-leg reservation creation in
one atomic unit, and six stored functions/procedures spanning two graph
models — the static route network (`Route`/`Route_Fare`) and the real,
time-expanded flight schedule (`Flight_Legs`) — each solved with the
algorithm actually suited to the question (DFS, Dijkstra, Bellman-Ford,
and a DAG shortest-path).

**Features.** Automatic delay computation via generated columns, a
Reservation/Booking model with real fares, a generated seat-inventory table
backing every seat assignment, an atomic multi-leg booking procedure, six
journey-search functions (three over the static route network, three
schedule-aware), a fully seeded sample dataset, and an ER diagram for quick
onboarding.

## Project files
- `aeroflow_schema_v2.sql` — table definitions, constraints, triggers, the
  atomic reservation procedure, and all six journey-planning functions
- `aeroflow_insert_data_v2.sql` — sample dataset (10 airlines, 20 aircraft +
  generated seat maps, 15 flights / 25 legs, 22 reservations, 30 bookings,
  and more) conformed to the schema
- `aeroflow_er_diagram.mermaid` — entity-relationship diagram
- `README.md` — this file


## ER diagram

See `aeroflow_er_diagram.mermaid` — renders natively in GitHub READMEs
(` ```mermaid ` code block) or the Mermaid Live Editor.

## Entity overview

- **Fleet**: `Airline` → `Aircraft` → `Aircraft_Seat_Map`, `Aircraft_Live_Status`, `Maintenance`
- **Infrastructure**: `Airport` → `Runway`, `Gate`
- **Network**: `Route` (airport pairs, priced by `Route_Fare`) → `Flight_Legs`
  (route + sequence per flight) → `Flight`
- **Crew**: `Pilot`, `Crew` assigned per-leg via `Pilot_Assign`, `Crew_Assign`
- **Passengers**: `User` → `Reservation` (one per purchase) → `Booking` (one
  per leg, tied to a specific seat + fare) → `Luggage`
- **Ground ops**: `Uses_Runway`, `Uses_Gate` (per-leg, per-airport usage)

## Journey planning (source → destination, graph queries)

These three requests are graph problems over the airport network — `Airport`
is a node, `Route` is a directed edge, `Route_Fare` is the edge weight — not
ordinary row-filtering queries, so each is implemented as a stored function
in `aeroflow_schema_v2.sql` using the algorithm actually suited to what it's
answering, rather than one generic approach stretched across all three:

| # | Question | Algorithm | Why this one |
|---|----------|-----------|---------------|
| 1 | All possible journeys | DFS via recursive CTE, path array as visited-set | Enumerating *every* simple path is inherently exponential — that's what "list them all" requires, any algorithm included |
| 2 | Cheapest journey | Dijkstra's algorithm | Finds the answer in polynomial time (O(V²+E) here) without ever enumerating all paths — the reason to prefer it over "run #1 and take MIN()" |
| 3 | Cheapest journey, ≤ k stops | Bellman-Ford, restricted to k+1 relaxation rounds | Dijkstra has no native hop-limit variant without expanding the state space to (node, stops-used) pairs; Bellman-Ford naturally bounds path length by the number of rounds run |

All three take an optional `p_seat_type` (`'Economy'` default or
`'Business'`) since fares differ by cabin class.

**1. All possible journeys between a source and destination, with total cost**
```sql
SELECT journey_path, num_stops, total_cost
FROM AeroFlow.fn_all_journeys(1, 7);   -- Airport 1 = AMD, Airport 7 = CCU
-- journey_path             | num_stops | total_cost
-- AMD -> CCU               | 0         | 9900.00
-- AMD -> DEL -> CCU        | 1         | 15200.00
-- AMD -> BOM -> DEL -> CCU | 2         | 18500.00
-- ... (8 total paths within the default 4-stop limit)
```
`p_max_stops` (default 4) bounds recursion depth; raise it if you need longer
itineraries. The cycle-blocking `NOT (dest = ANY(path))` check means it never
loops forever even without that bound — it just controls how deep the DFS
goes.

**2. The single cheapest journey**
```sql
SELECT journey_path, total_cost
FROM AeroFlow.fn_cheapest_journey(1, 7);
-- AMD -> CCU | 9900.00
```

**3. Cheapest journey with at most k stops**
```sql
SELECT journey_path, num_stops, total_cost
FROM AeroFlow.fn_cheapest_journey_k_stops(1, 5, 1);   -- AMD -> MAA, at most 1 stop
-- AMD -> CCU -> MAA | 1 | 16600.00
```
This is a case where query #3 genuinely disagrees with query #2's unconstrained
answer: `fn_cheapest_journey(1, 5)` (Dijkstra, no stop limit) returns
`AMD -> BOM -> BLR -> MAA` at **16400.00** — 2 stops, cheaper overall, but over
budget. Dijkstra can't be asked "cheapest subject to ≤1 stop" without
tracking (node, stops-used) as extra state; the round-limited Bellman-Ford
handles that constraint natively, which is exactly why query #3 needs its
own algorithm rather than reusing #2.

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
