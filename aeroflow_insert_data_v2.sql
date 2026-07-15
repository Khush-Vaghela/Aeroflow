-- ============================================================
-- AeroFlow PostgreSQL — INSERT DATA SCRIPTS (v2)
-- ============================================================
-- Conformed to aeroflow_schema_v2.sql. Key differences from the
-- original insert script:
--   1. Aircraft split into Aircraft (static specs) + Aircraft_Live_Status
--      (telemetry). Each v1 Aircraft row now produces one row in each.
--   2. Flight no longer carries Source/Dest airport columns; those
--      are derivable via Flight_Legs -> Route (see README query).
--   3. Flight & Flight_Legs now use Scheduled_*/Actual_* timestamp
--      pairs instead of single Departure/Arrival/Takeoff/Landing
--      columns. Scheduled times are taken from the (authoritative,
--      most granular) leg-level data; a handful of flights are
--      given non-zero actual delays to demonstrate the generated
--      delay columns, the rest are on-time (Actual = Scheduled).
--   4. Status values conformed to the new CHECK-constrained enums:
--        Flight/Leg status:  Completed -> Landed, In-Flight -> InAir
--        Maintenance_Status: In-Progress -> InProgress
--        Runway.Status:      Active -> Open
--   5. Booking insert omits Created_At (defaults to NOW()).
--   6. Booking_Status 'Waitlisted' required extending the schema's
--      CHECK constraint (done in aeroflow_schema_v2.sql) — a real
--      booking state the original enum missed.
--   7. Flight/Flight_Legs timestamps are now computed relative to
--      CURRENT_DATE/CURRENT_TIMESTAMP (not hardcoded 2024 dates) so
--      "last N days" and "currently in progress" queries always
--      return rows no matter when this script is run. Flight 1002
--      now carries a >30-min departure delay to populate the
--      delayed-flights query, and Pilot 203 is deliberately double-
--      booked across Flights 1002/1006 to populate the conflict-
--      audit query.
--   8. Booking 530's Seat_Number is now NULL (Waitlisted bookings
--      hold no real seat, per the new Booking CHECK constraint) and
--      is paired with Booking 510 (Confirmed, same flight/leg/seat
--      type) so cancelling 510 demonstrates the waitlist-promotion
--      trigger — see README "Testing the waitlist trigger".
--   9. Reservation (22 records) replaces User_ID/Booking_Date/the
--      redundant Booking_Sequence_No on Booking — each reservation
--      groups one purchase's legs under one PNR-style record.
--      Route_Fare (40 records) is a new base-fare catalog (Route x
--      Seat_Type), independent of Booking.Fare_Amount (what was
--      actually charged historically); it backs the journey-
--      planning functions in aeroflow_schema_v2.sql.
-- ============================================================

SET SEARCH_PATH TO AeroFlow;

-- ============================================================
-- 1. AIRLINE (10 records) — unchanged
-- ============================================================

INSERT INTO Airline VALUES
(1,  'IndiGo',               'India',  'Gurugram, Haryana',     'indigo@indigo.in',      '6E'),
(2,  'Air India',            'India',  'New Delhi',             'airindia@airindia.in',  'AI'),
(3,  'SpiceJet',             'India',  'Gurugram, Haryana',     'spicejet@jet.com',      'SG'),
(4,  'Vistara',              'India',  'Gurugram, Haryana',     'vistara@vistara.com',   'UK'),
(5,  'GoFirst',              'India',  'Mumbai, Maharashtra',   'gofirst@gofirst.in',    'G8'),
(6,  'AirAsia India',        'India',  'Bengaluru, Karnataka',  'airasia@airasia.in',    'I5'),
(7,  'Blue Dart Aviation',   'India',  'Mumbai, Maharashtra',   'bdaviation@bd.in',      'BZ'),
(8,  'Alliance Air',         'India',  'Bengaluru, Karnataka',  'alliance@air.in',       'CD'),
(9,  'Star Air',             'India',  'Bengaluru, Karnataka',  'starair@starair.in',    'OG'),
(10, 'Akasa Air',            'India',  'Mumbai, Maharashtra',   'akasa@akasaair.in',     'QP');


-- ============================================================
-- 2. AIRCRAFT (20 records) — static specs only
-- ============================================================

INSERT INTO Aircraft
    (Aircraft_ID, Airline_ID, Model, Manufacture_Date, Total_Flight_Hours,
     Total_Flight_Cycle, Tot_Eco_Seats, Tot_Bus_Seats, Total_Fuel_Capacity)
VALUES
(101, 1,  'Airbus A320neo',   '2018-03-15', 12400, 2100, 180, 0,   26000.00),
(102, 1,  'Airbus A321neo',   '2019-07-20', 9800,  1650, 220, 12,  29000.00),
(103, 2,  'Boeing 787-8',     '2017-01-10', 18600, 3200, 238, 30,  126000.00),
(104, 2,  'Boeing 777-300ER', '2015-06-05', 24300, 4100, 304, 48,  145000.00),
(105, 3,  'Boeing 737-800',   '2020-02-28', 5600,  980,  189, 12,  26022.00),
(106, 3,  'Boeing 737 MAX 8', '2021-09-14', 3200,  540,  178, 8,   25816.00),
(107, 4,  'Airbus A320',      '2016-11-22', 21000, 3600, 158, 16,  24210.00),
(108, 4,  'Airbus A321',      '2017-04-30', 19500, 3300, 194, 20,  26800.00),
(109, 5,  'Airbus A320neo',   '2022-01-05', 1800,  310,  186, 0,   26000.00),
(110, 6,  'Airbus A320',      '2019-08-17', 8700,  1480, 180, 12,  24210.00),
(111, 6,  'ATR 72-600',       '2020-05-12', 4300,  920,  70,  0,   6370.00),
(112, 7,  'Boeing 737-400SF', '2014-03-08', 31200, 5400, 0,   0,   26022.00),
(113, 8,  'ATR 42-300',       '2013-10-19', 38000, 6800, 48,  0,   5780.00),
(114, 9,  'Embraer E175',     '2021-06-25', 2900,  490,  78,  8,   13986.00),
(115, 10, 'Boeing 737 MAX 8', '2022-11-30', 1100,  190,  189, 12,  25816.00),
(116, 1,  'Airbus A320neo',   '2020-06-10', 7200,  1220, 180, 0,   26000.00),
(117, 2,  'Boeing 787-9',     '2018-09-22', 14600, 2500, 256, 42,  126900.00),
(118, 3,  'Boeing 737-700',   '2016-04-14', 22800, 3900, 128, 8,   26022.00),
(119, 4,  'Airbus A320neo',   '2023-02-08', 800,   130,  180, 16,  26000.00),
(120, 5,  'Airbus A321neo',   '2021-12-01', 3600,  610,  220, 12,  29000.00);


-- ============================================================
-- 2b. AIRCRAFT_LIVE_STATUS (20 records) — telemetry, 1:1 with Aircraft
-- ============================================================

INSERT INTO Aircraft_Live_Status
    (Aircraft_ID, Current_Fuel_Level, Location, Status_Type, Current_Speed,
     Autopilot_Status, Cabin_Pressure_PSI, Outside_Air_Temperature, Altitude,
     Is_In_Aviation, Last_Updated)
VALUES
(101, 18500.00, 'Ahmedabad',  'Active',      820.00, 'Engaged',  8.20,  -56.00, 33000.000, TRUE,  '2024-06-01 00:00:00'),
(102, 22000.00, 'Mumbai',     'Active',      840.00, 'Engaged',  8.30,  -52.00, 35000.000, TRUE,  '2024-06-01 00:00:00'),
(103, 95000.00, 'Delhi',      'Active',      900.00, 'Engaged',  8.00,  -60.00, 38000.000, TRUE,  '2024-06-01 00:00:00'),
(104, 110000.00,'Kolkata',    'Active',      905.00, 'Engaged',  8.10,  -58.00, 39000.000, TRUE,  '2024-06-01 00:00:00'),
(105, 19000.00, 'Chennai',    'Active',      810.00, 'Engaged',  8.25,  -55.00, 32000.000, TRUE,  '2024-06-01 00:00:00'),
(106, 17500.00, 'Hyderabad',  'Active',      830.00, 'Engaged',  8.20,  -54.00, 33000.000, TRUE,  '2024-06-01 00:00:00'),
(107, 15000.00, 'Bengaluru',  'Active',      820.00, 'Engaged',  8.15,  -57.00, 34000.000, TRUE,  '2024-06-01 00:00:00'),
(108, 20000.00, 'Pune',       'Maintenance', 0.00,   'Off',      NULL,  NULL,   NULL,      FALSE, '2024-06-01 00:00:00'),
(109, 24000.00, 'Ahmedabad',  'Active',      815.00, 'Engaged',  8.22,  -53.00, 31000.000, TRUE,  '2024-06-01 00:00:00'),
(110, 16000.00, 'Mumbai',     'Active',      820.00, 'Standby',  8.18,  -55.00, 30000.000, TRUE,  '2024-06-01 00:00:00'),
(111, 4800.00,  'Surat',      'Active',      510.00, 'Engaged',  7.80,  -48.00, 18000.000, TRUE,  '2024-06-01 00:00:00'),
(112, 20000.00, 'Delhi',      'Active',      800.00, 'Engaged',  8.10,  -56.00, 32000.000, TRUE,  '2024-06-01 00:00:00'),
(113, 3500.00,  'Jaipur',     'Active',      490.00, 'Standby',  7.70,  -46.00, 16000.000, TRUE,  '2024-06-01 00:00:00'),
(114, 10000.00, 'Bengaluru',  'Active',      820.00, 'Engaged',  8.05,  -52.00, 37000.000, TRUE,  '2024-06-01 00:00:00'),
(115, 22000.00, 'Mumbai',     'Active',      825.00, 'Engaged',  8.20,  -54.00, 33000.000, TRUE,  '2024-06-01 00:00:00'),
(116, 17000.00, 'Jaipur',     'Active',      818.00, 'Engaged',  8.19,  -55.00, 32500.000, TRUE,  '2024-06-01 00:00:00'),
(117, 98000.00, 'Mumbai',     'Active',      903.00, 'Engaged',  7.98,  -61.00, 39000.000, TRUE,  '2024-06-01 00:00:00'),
(118, 18000.00, 'Delhi',      'Grounded',    0.00,   'Off',      NULL,  NULL,   NULL,      FALSE, '2024-06-01 00:00:00'),
(119, 25000.00, 'Hyderabad',  'Active',      812.00, 'Standby',  8.21,  -53.00, 31500.000, FALSE, '2024-06-01 00:00:00'),
(120, 23000.00, 'Chennai',    'Active',      838.00, 'Engaged',  8.28,  -52.00, 34000.000, TRUE,  '2024-06-01 00:00:00');


-- ============================================================
-- 3. AIRPORT (12 records) — unchanged
-- ============================================================

INSERT INTO Airport VALUES
(1,  'Sardar Vallabhbhai Patel International Airport',    'Ahmedabad', 'Gujarat',       'India', 'AMD'),
(2,  'Chhatrapati Shivaji Maharaj International Airport', 'Mumbai',    'Maharashtra',   'India', 'BOM'),
(3,  'Indira Gandhi International Airport',               'New Delhi', 'Delhi',         'India', 'DEL'),
(4,  'Kempegowda International Airport',                  'Bengaluru', 'Karnataka',     'India', 'BLR'),
(5,  'Chennai International Airport',                     'Chennai',   'Tamil Nadu',    'India', 'MAA'),
(6,  'Rajiv Gandhi International Airport',                'Hyderabad', 'Telangana',     'India', 'HYD'),
(7,  'Netaji Subhas Chandra Bose International Airport',  'Kolkata',   'West Bengal',   'India', 'CCU'),
(8,  'Jaipur International Airport',                      'Jaipur',    'Rajasthan',     'India', 'JAI'),
(9,  'Pune Airport',                                      'Pune',      'Maharashtra',   'India', 'PNQ'),
(10, 'Surat Airport',                                     'Surat',     'Gujarat',       'India', 'STV'),
(11, 'Goa International Airport',                         'Goa',       'Goa',           'India', 'GOI'),
(12, 'Lal Bahadur Shastri International Airport',         'Varanasi',  'Uttar Pradesh', 'India', 'VNS');


-- ============================================================
-- 4. RUNWAY (28 records) — Status 'Active' -> 'Open' to match
--    the new CHECK (Status IN ('Open','Closed','Maintenance'))
-- ============================================================

INSERT INTO Runway VALUES
(1,  1, 'Asphalt',  3505.00, 'Open'),
(1,  2, 'Asphalt',  2996.00, 'Open'),
(2,  1, 'Concrete', 3660.00, 'Open'),
(2,  2, 'Concrete', 2925.00, 'Open'),
(2,  3, 'Asphalt',  1524.00, 'Open'),
(3,  1, 'Concrete', 4430.00, 'Open'),
(3,  2, 'Concrete', 3810.00, 'Open'),
(3,  3, 'Asphalt',  2813.00, 'Open'),
(4,  1, 'Asphalt',  4000.00, 'Open'),
(4,  2, 'Asphalt',  2920.00, 'Open'),
(5,  1, 'Asphalt',  3658.00, 'Open'),
(5,  2, 'Concrete', 2990.00, 'Closed'),
(6,  1, 'Concrete', 4260.00, 'Open'),
(6,  2, 'Asphalt',  3200.00, 'Open'),
(7,  1, 'Asphalt',  3627.00, 'Open'),
(7,  2, 'Concrete', 2700.00, 'Open'),
(8,  1, 'Asphalt',  2738.00, 'Open'),
(8,  2, 'Asphalt',  1800.00, 'Maintenance'),
(9,  1, 'Asphalt',  2515.00, 'Open'),
(9,  2, 'Concrete', 1800.00, 'Open'),
(10, 1, 'Asphalt',  2905.00, 'Open'),
(10, 2, 'Asphalt',  1500.00, 'Open'),
(11, 1, 'Asphalt',  3400.00, 'Open'),
(11, 2, 'Concrete', 2100.00, 'Open'),
(12, 1, 'Asphalt',  2743.00, 'Open'),
(12, 2, 'Asphalt',  1500.00, 'Closed'),
(3,  4, 'Concrete', 2813.00, 'Open'),
(2,  4, 'Asphalt',  1200.00, 'Maintenance');


-- ============================================================
-- 5. GATE (30 records) — unchanged
-- ============================================================

INSERT INTO Gate VALUES
(1,  1, 'Available'), (1,  2, 'Occupied'),  (1,  3, 'Available'),
(2,  1, 'Occupied'),  (2,  2, 'Available'), (2,  3, 'Occupied'),  (2,  4, 'Available'),
(3,  1, 'Available'), (3,  2, 'Available'), (3,  3, 'Occupied'),  (3,  4, 'Occupied'),  (3, 5, 'Available'),
(4,  1, 'Available'), (4,  2, 'Occupied'),  (4,  3, 'Available'),
(5,  1, 'Available'), (5,  2, 'Available'),
(6,  1, 'Occupied'),  (6,  2, 'Available'), (6,  3, 'Available'),
(7,  1, 'Available'), (7,  2, 'Occupied'),
(8,  1, 'Available'), (8,  2, 'Available'),
(9,  1, 'Available'), (9,  2, 'Occupied'),
(10, 1, 'Available'), (11, 1, 'Available'), (12, 1, 'Available');


-- ============================================================
-- 6. ROUTE (20 records) — unchanged
-- ============================================================
-- Route distances in km; estimated_duration in minutes

INSERT INTO Route VALUES
(1,   533.00,  75,  1, 2),   -- AMD -> BOM
(2,   533.00,  75,  2, 1),   -- BOM -> AMD
(3,   935.00, 120,  1, 3),   -- AMD -> DEL
(4,   935.00, 120,  3, 1),   -- DEL -> AMD
(5,   888.00, 110,  2, 4),   -- BOM -> BLR
(6,   888.00, 110,  4, 2),   -- BLR -> BOM
(7,  1398.00, 170,  1, 7),   -- AMD -> CCU
(8,   700.00,  90,  2, 3),   -- BOM -> DEL
(9,   700.00,  90,  3, 2),   -- DEL -> BOM
(10,  860.00, 105,  3, 4),   -- DEL -> BLR
(11,  860.00, 105,  4, 3),   -- BLR -> DEL
(12,  660.00,  85,  2, 6),   -- BOM -> HYD
(13,  660.00,  85,  6, 2),   -- HYD -> BOM
(14,  570.00,  80,  4, 5),   -- BLR -> MAA
(15,  570.00,  80,  5, 4),   -- MAA -> BLR
(16,  468.00,  65,  3, 8),   -- DEL -> JAI
(17,  468.00,  65,  8, 3),   -- JAI -> DEL
(18,  864.00, 110,  5, 7),   -- MAA -> CCU
(19,  864.00, 110,  7, 5),   -- CCU -> MAA
(20, 1095.00, 140,  3, 7);   -- DEL -> CCU


-- ============================================================
-- 6b. ROUTE_FARE (40 records — Economy + Business per route)
-- ============================================================
-- Fare = base fee + per-km rate (Economy ~Rs.6/km + Rs.1500 base;
-- Business ~Rs.15/km + Rs.4000 base), rounded to a clean figure.
-- This is the "current listed price" catalog used to plan/quote
-- new journeys (see the journey-planning functions further down);
-- it's independent of what any specific Booking was historically
-- charged (Booking.Fare_Amount).

INSERT INTO Route_Fare VALUES
(1,  'Economy', 4700.00), (1,  'Business', 12000.00),
(2,  'Economy', 4700.00), (2,  'Business', 12000.00),
(3,  'Economy', 7100.00), (3,  'Business', 18000.00),
(4,  'Economy', 7100.00), (4,  'Business', 18000.00),
(5,  'Economy', 6800.00), (5,  'Business', 17300.00),
(6,  'Economy', 6800.00), (6,  'Business', 17300.00),
(7,  'Economy', 9900.00), (7,  'Business', 25000.00),
(8,  'Economy', 5700.00), (8,  'Business', 14500.00),
(9,  'Economy', 5700.00), (9,  'Business', 14500.00),
(10, 'Economy', 6700.00), (10, 'Business', 16900.00),
(11, 'Economy', 6700.00), (11, 'Business', 16900.00),
(12, 'Economy', 5500.00), (12, 'Business', 13900.00),
(13, 'Economy', 5500.00), (13, 'Business', 13900.00),
(14, 'Economy', 4900.00), (14, 'Business', 12600.00),
(15, 'Economy', 4900.00), (15, 'Business', 12600.00),
(16, 'Economy', 4300.00), (16, 'Business', 11000.00),
(17, 'Economy', 4300.00), (17, 'Business', 11000.00),
(18, 'Economy', 6700.00), (18, 'Business', 17000.00),
(19, 'Economy', 6700.00), (19, 'Business', 17000.00),
(20, 'Economy', 8100.00), (20, 'Business', 20400.00);


-- ============================================================
-- 7. FLIGHT (15 records)
-- ============================================================
-- Dates are computed relative to CURRENT_DATE/CURRENT_TIMESTAMP
-- (rather than hardcoded 2024 literals) so that "last 30 days"
-- and "currently in progress" style queries always return rows,
-- regardless of when this script is run.
--   Day A = today - 10 days   (flights 1001-1009, all Landed)
--   Day B = today - 9 days    (flights 1010-1012, 1014, Landed)
--   "now" (flight 1013)       (departed ~2h ago, still InAir)
--   Day C = today + 2 days    (flight 1015, Scheduled/future)
-- Flight 1002 carries a deliberate 45-min departure delay (>30 min)
-- to populate the "flights delayed on departure" query; Flight 1008
-- carries a 20-min arrival delay. Everything else is on-time.

INSERT INTO Flight
    (Flight_ID, Aircraft_ID, Scheduled_Departure_Time, Scheduled_Arrival_Time,
     Actual_Departure_Time, Actual_Arrival_Time, Flight_Status)
VALUES
(1001, 101, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 50 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 50 minutes',  'Landed'),
(1002, 102, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 30 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 15 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours 30 minutes', 'Landed'),
(1003, 103, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 20 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 20 minutes',  'Landed'),
(1004, 104, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 50 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 50 minutes',  'Landed'),
(1005, 105, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 20 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 20 minutes',  'Landed'),
(1006, 107, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 20 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 20 minutes',  'Landed'),
(1007, 109, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours 15 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours 15 minutes',  'Landed'),
(1008, 110, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '13 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '17 hours 55 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '13 hours',   CURRENT_DATE - INTERVAL '10 days' + INTERVAL '18 hours 15 minutes',  'Landed'),
(1009, 111, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 10 minutes',
            CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours',    CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 10 minutes',   'Landed'),
(1010, 114, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 45 minutes',
            CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 45 minutes',   'Landed'),
(1011, 115, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 10 minutes',
            CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 10 minutes',   'Landed'),
(1012, 116, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 30 minutes', CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '9 hours 35 minutes',
            CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 30 minutes', CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '9 hours 35 minutes',   'Landed'),
(1013, 117, CURRENT_TIMESTAMP - INTERVAL '2 hours', CURRENT_TIMESTAMP - INTERVAL '2 hours' + INTERVAL '4 hours',
            CURRENT_TIMESTAMP - INTERVAL '2 hours', NULL,                                                        'InAir'),
(1014, 120, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 50 minutes',
            CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',    CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 50 minutes',   'Landed'),
(1015, 103, CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '10 hours',   CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '14 hours 5 minutes',
            NULL, NULL, 'Scheduled');


-- ============================================================
-- 8. FLIGHT_LEGS (25 records)
-- ============================================================
-- Same relative-date scheme as Flight above; each leg's scheduled
-- times match the flight-level times it rolls up into.

INSERT INTO Flight_Legs
    (Flight_ID, Route_ID, Leg_Sequence_No, Scheduled_Takeoff_Time, Scheduled_Landing_Time,
     Actual_Takeoff_Time, Actual_Landing_Time, Leg_Status)
VALUES
-- Flight 1001: AMD->BOM->BLR
(1001, 1,  1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours 15 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours 15 minutes', 'Landed'),
(1001, 5,  2, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 50 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 50 minutes', 'Landed'),
-- Flight 1002: BOM->DEL (direct) — 45 min departure delay, 60 min arrival delay
(1002, 8,  1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 30 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 15 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours 30 minutes', 'Landed'),
-- Flight 1003: AMD->DEL->CCU
(1003, 3,  1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours', 'Landed'),
(1003, 20, 2, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 20 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 20 minutes', 'Landed'),
-- Flight 1004: DEL->BLR->MAA
(1004, 10, 1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 45 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '9 hours 45 minutes', 'Landed'),
(1004, 14, 2, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 50 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 50 minutes', 'Landed'),
-- Flight 1005: BLR->MAA (direct)
(1005, 14, 1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 20 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '10 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours 20 minutes', 'Landed'),
-- Flight 1006: DEL->BLR (direct)
(1006, 10, 1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 20 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '6 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 20 minutes', 'Landed'),
-- Flight 1007: AMD->BOM (direct)
(1007, 1,  1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours 15 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '11 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '12 hours 15 minutes', 'Landed'),
-- Flight 1008: BOM->HYD->CCU — on-time departure, 20 min late into CCU
(1008, 12, 1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '13 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 25 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '13 hours', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '14 hours 25 minutes', 'Landed'),
(1008, 18, 2, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '15 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '17 hours 55 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '15 hours 30 minutes', CURRENT_DATE - INTERVAL '10 days' + INTERVAL '18 hours 15 minutes', 'Landed'),
-- Flight 1009: STV->BOM (reuse route 1 reversed, approximate)
(1009, 2,  1, CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 10 minutes',
              CURRENT_DATE - INTERVAL '10 days' + INTERVAL '7 hours',  CURRENT_DATE - INTERVAL '10 days' + INTERVAL '8 hours 10 minutes', 'Landed'),
-- Flight 1010: BLR->DEL (direct)
(1010, 11, 1, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 45 minutes',
              CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 45 minutes', 'Landed'),
-- Flight 1011: BOM->HYD (direct)
(1011, 12, 1, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 10 minutes',
              CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 10 minutes', 'Landed'),
-- Flight 1012: JAI->DEL (direct)
(1012, 17, 1, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 30 minutes', CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '9 hours 35 minutes',
              CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '8 hours 30 minutes', CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '9 hours 35 minutes', 'Landed'),
-- Flight 1013: BOM->HYD->CCU — leg 1 airborne right now, leg 2 not yet departed
(1013, 12, 1, CURRENT_TIMESTAMP - INTERVAL '2 hours', CURRENT_TIMESTAMP - INTERVAL '2 hours' + INTERVAL '1 hour 10 minutes',
              CURRENT_TIMESTAMP - INTERVAL '2 hours', NULL, 'InAir'),
(1013, 18, 2, CURRENT_TIMESTAMP - INTERVAL '2 hours' + INTERVAL '2 hours 10 minutes', CURRENT_TIMESTAMP - INTERVAL '2 hours' + INTERVAL '4 hours',
              NULL, NULL, 'Scheduled'),
-- Flight 1014: MAA->CCU (direct)
(1014, 18, 1, CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 50 minutes',
              CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '6 hours',  CURRENT_DATE - INTERVAL '9 days'  + INTERVAL '7 hours 50 minutes', 'Landed'),
-- Flight 1015: BLR->MAA->CCU — future, not yet departed
(1015, 14, 1, CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '10 hours', CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '11 hours 20 minutes', NULL, NULL, 'Scheduled'),
(1015, 18, 2, CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '12 hours 15 minutes', CURRENT_DATE + INTERVAL '2 days'  + INTERVAL '14 hours 5 minutes', NULL, NULL, 'Scheduled');


-- ============================================================
-- 9. PILOT (20 records) — unchanged
-- ============================================================

INSERT INTO Pilot VALUES
(201, 'Capt. Rajesh Sharma',  'DGCA-IND-2003-0021', 'rajesh.s@aeroflow.in',  'Senior Captain'),
(202, 'Capt. Priya Mehta',    'DGCA-IND-2007-0045', 'priya.m@aeroflow.in',   'Captain'),
(203, 'Capt. Arjun Nair',     'DGCA-IND-2005-0033', 'arjun.n@aeroflow.in',   'Senior Captain'),
(204, 'FO Sneha Patel',       'DGCA-IND-2015-0089', 'sneha.p@aeroflow.in',   'First Officer'),
(205, 'FO Vikas Reddy',       'DGCA-IND-2016-0102', 'vikas.r@aeroflow.in',   'First Officer'),
(206, 'Capt. Amit Joshi',     'DGCA-IND-2004-0028', 'amit.j@aeroflow.in',    'Senior Captain'),
(207, 'FO Neha Singh',        'DGCA-IND-2018-0134', 'neha.s@aeroflow.in',    'First Officer'),
(208, 'Capt. Kiran Kumar',    'DGCA-IND-2006-0041', 'kiran.k@aeroflow.in',   'Captain'),
(209, 'FO Ravi Tiwari',       'DGCA-IND-2019-0156', 'ravi.t@aeroflow.in',    'First Officer'),
(210, 'Capt. Divya Pillai',   'DGCA-IND-2008-0057', 'divya.p@aeroflow.in',   'Captain'),
(211, 'FO Manish Gupta',      'DGCA-IND-2017-0118', 'manish.g@aeroflow.in',  'First Officer'),
(212, 'Capt. Sunita Rao',     'DGCA-IND-2009-0063', 'sunita.r@aeroflow.in',  'Captain'),
(213, 'FO Deepak Verma',      'DGCA-IND-2020-0178', 'deepak.v@aeroflow.in',  'First Officer'),
(214, 'Capt. Rohit Bhat',     'DGCA-IND-2001-0009', 'rohit.b@aeroflow.in',   'Senior Captain'),
(215, 'FO Ananya Iyer',       'DGCA-IND-2021-0195', 'ananya.i@aeroflow.in',  'First Officer'),
(216, 'Capt. Sanjay Desai',   'DGCA-IND-2002-0015', 'sanjay.d@aeroflow.in',  'Senior Captain'),
(217, 'FO Pooja Malhotra',    'DGCA-IND-2022-0210', 'pooja.m@aeroflow.in',   'First Officer'),
(218, 'Capt. Vikram Chauhan', 'DGCA-IND-2010-0074', 'vikram.c@aeroflow.in',  'Captain'),
(219, 'FO Rahul Pandey',      'DGCA-IND-2019-0162', 'rahul.p@aeroflow.in',   'First Officer'),
(220, 'Capt. Meera Krishnan', 'DGCA-IND-2011-0082', 'meera.k@aeroflow.in',   'Captain');


-- ============================================================
-- 10. CREW (20 records) — unchanged
-- ============================================================

INSERT INTO Crew VALUES
(301, 'Aisha Khan',         'Cabin Manager',           8,  'Hindi, English, Urdu'),
(302, 'Preethi Sundaram',   'Senior Flight Attendant', 6,  'Tamil, English, Hindi'),
(303, 'Rohan Mehta',        'Flight Attendant',        3,  'Hindi, English'),
(304, 'Simran Batra',       'Flight Attendant',        4,  'Punjabi, Hindi, English'),
(305, 'Karthik Rajan',      'Senior Flight Attendant', 7,  'Tamil, Telugu, English'),
(306, 'Naina Sharma',       'Flight Attendant',        2,  'Hindi, English'),
(307, 'Tarun Bose',         'Cabin Manager',           10, 'Bengali, Hindi, English'),
(308, 'Lakshmi Iyer',       'Senior Flight Attendant', 9,  'Tamil, Kannada, English'),
(309, 'Siddharth Jain',     'Flight Attendant',        1,  'Hindi, English'),
(310, 'Preeti Gupta',       'Flight Attendant',        5,  'Hindi, English, Marathi'),
(311, 'Ayesha Thomas',      'Cabin Manager',           12, 'Malayalam, English, Hindi'),
(312, 'Vikrant Singh',      'Senior Flight Attendant', 6,  'Hindi, English'),
(313, 'Sunanda Patil',      'Flight Attendant',        3,  'Marathi, Hindi, English'),
(314, 'Deepika Nair',       'Flight Attendant',        4,  'Malayalam, Tamil, English'),
(315, 'Rahul Saxena',       'Cabin Manager',           7,  'Hindi, English'),
(316, 'Meenakshi Rao',      'Senior Flight Attendant', 5,  'Telugu, Kannada, English'),
(317, 'Ankit Verma',        'Flight Attendant',        2,  'Hindi, English'),
(318, 'Jyoti Kaur',         'Flight Attendant',        6,  'Punjabi, Hindi, English'),
(319, 'Suresh Pillai',      'Cabin Manager',           15, 'Malayalam, Tamil, Hindi, English'),
(320, 'Rashmi Patel',       'Flight Attendant',        1,  'Gujarati, Hindi, English');


-- ============================================================
-- 11. USER (20 records) — unchanged
-- ============================================================

INSERT INTO "User" VALUES
(401, 'Aditya Kapoor',  'aditya.k@gmail.com',  '9876543210', '14 MG Road, Bengaluru, Karnataka 560001'),
(402, 'Bhavna Shah',    'bhavna.s@gmail.com',  '9812345678', '7 Nehru Street, Ahmedabad, Gujarat 380001'),
(403, 'Chirag Desai',   'chirag.d@yahoo.com',  '9823456789', '21 Marine Drive, Mumbai, Maharashtra 400001'),
(404, 'Divya Pillai',   'divya.p@outlook.com', '9834567890', '3 Anna Nagar, Chennai, Tamil Nadu 600040'),
(405, 'Eshan Trivedi',  'eshan.t@gmail.com',   '9845678901', '5 Connaught Place, New Delhi 110001'),
(406, 'Falguni Mehta',  'falguni.m@gmail.com', '9856789012', '10 CG Road, Ahmedabad, Gujarat 380009'),
(407, 'Gautam Rao',     'gautam.r@yahoo.com',  '9867890123', '88 Jubilee Hills, Hyderabad, Telangana 500033'),
(408, 'Hema Nair',      'hema.n@gmail.com',    '9878901234', '17 Koregaon Park, Pune, Maharashtra 411001'),
(409, 'Ishaan Bose',    'ishaan.b@gmail.com',  '9889012345', '45 Park Street, Kolkata, West Bengal 700016'),
(410, 'Jaya Krishnan',  'jaya.k@outlook.com',  '9890123456', '6 Jayanagar, Bengaluru, Karnataka 560011'),
(411, 'Karan Malhotra', 'karan.m@gmail.com',   '9901234567', '22 Rajouri Garden, New Delhi 110027'),
(412, 'Leena Sharma',   'leena.s@yahoo.com',   '9912345678', '9 Tilak Nagar, Jaipur, Rajasthan 302004'),
(413, 'Mohan Iyer',     'mohan.i@gmail.com',   '9923456789', '33 T Nagar, Chennai, Tamil Nadu 600017'),
(414, 'Nandita Gupta',  'nandita.g@gmail.com', '9934567890', '12 Kalighat, Kolkata, West Bengal 700026'),
(415, 'Om Prakash',     'om.p@outlook.com',    '9945678901', '4 Lal Darwaja, Surat, Gujarat 395003'),
(416, 'Pallavi Reddy',  'pallavi.r@gmail.com', '9956789012', '55 Banjara Hills, Hyderabad, Telangana 500034'),
(417, 'Qureshi Azam',   'qureshi.a@gmail.com', '9967890123', '8 Civil Lines, Jaipur, Rajasthan 302006'),
(418, 'Ritu Bhatt',     'ritu.b@yahoo.com',    '9978901234', '19 Satellite, Ahmedabad, Gujarat 380015'),
(419, 'Suresh Varma',   'suresh.v@gmail.com',  '9989012345', '67 Bandra West, Mumbai, Maharashtra 400050'),
(420, 'Tanya Singh',    'tanya.s@gmail.com',   '9990123456', '2 Model Town, New Delhi 110009');


-- ============================================================
-- 11b. RESERVATION (22 records)
-- ============================================================
-- One row per purchase; groups a passenger's legs for one journey.
-- Total fare is intentionally not stored — derive with
-- SUM(Booking.Fare_Amount) WHERE Reservation_ID = ... (see README).

INSERT INTO Reservation (Reservation_ID, User_ID, Booking_Date, Reservation_Status) VALUES
(801, 401, '2024-05-20', 'Active'),     -- AMD->BOM->BLR
(802, 402, '2024-05-18', 'Active'),     -- BOM->DEL (Business)
(803, 403, '2024-05-22', 'Active'),     -- AMD->DEL->CCU
(804, 404, '2024-05-23', 'Active'),     -- DEL->BLR->MAA
(805, 405, '2024-05-25', 'Active'),     -- BLR->MAA
(806, 406, '2024-05-15', 'Active'),     -- DEL->BLR (Business)
(807, 407, '2024-05-28', 'Active'),     -- AMD->BOM (seat 30E — see waitlist demo below)
(808, 408, '2024-05-19', 'Active'),     -- BOM->HYD->CCU
(809, 409, '2024-05-30', 'Active'),     -- STV->BOM
(810, 410, '2024-05-21', 'Active'),     -- BLR->DEL (Business)
(811, 411, '2024-05-24', 'Active'),     -- BOM->HYD
(812, 412, '2024-05-26', 'Active'),     -- JAI->DEL
(813, 413, '2024-05-27', 'Active'),     -- BOM->HYD->CCU (Flight 1013, currently InAir)
(814, 414, '2024-05-29', 'Active'),     -- MAA->CCU
(815, 415, '2024-05-31', 'Active'),     -- BLR->MAA->CCU (Flight 1015, future)
(816, 416, '2024-05-20', 'Active'),     -- AMD->BOM->BLR
(817, 417, '2024-05-18', 'Cancelled'),  -- BOM->DEL, sole leg cancelled
(818, 418, '2024-05-22', 'Active'),     -- AMD->DEL->CCU (Business)
(819, 419, '2024-05-25', 'Active'),     -- BLR->MAA
(820, 420, '2024-05-15', 'Active'),     -- DEL->BLR
(821, 403, '2024-05-17', 'Active'),     -- BOM->DEL (Chirag's 2nd, separate trip)
(822, 402, '2024-05-28', 'Active');     -- Waitlisted for AMD->BOM (see waitlist demo below)


-- ============================================================
-- 12. BOOKING (30 records)
-- ============================================================
-- Created_At omitted -> defaults to NOW(). Fare_Amount is looked up
-- from Route_Fare at the booking's route + seat type. 'Waitlisted'
-- status required extending the schema's Booking_Status CHECK
-- constraint (see aeroflow_schema_v2.sql).

INSERT INTO Booking
    (Booking_ID, Reservation_ID, Flight_ID, Route_ID, Leg_Sequence_No,
     Seat_Type, Seat_Number, Fare_Amount, Booking_Status)
VALUES
(501, 801, 1001, 1,  1, 'Economy', '14A', 4700.00,  'Confirmed'),
(502, 801, 1001, 5,  2, 'Economy', '14A', 6800.00,  'Confirmed'),
(503, 802, 1002, 8,  1, 'Business','2C',  14500.00, 'Confirmed'),
(504, 803, 1003, 3,  1, 'Economy', '22B', 7100.00,  'Confirmed'),
(505, 803, 1003, 20, 2, 'Economy', '22B', 8100.00,  'Confirmed'),
(506, 804, 1004, 10, 1, 'Economy', '18C', 6700.00,  'Confirmed'),
(507, 804, 1004, 14, 2, 'Economy', '18C', 4900.00,  'Confirmed'),
(508, 805, 1005, 14, 1, 'Economy', '5D',  4900.00,  'Confirmed'),
(509, 806, 1006, 10, 1, 'Business','1A',  16900.00, 'Confirmed'),
(510, 807, 1007, 1,  1, 'Economy', '30E', 4700.00,  'Confirmed'),
(511, 808, 1008, 12, 1, 'Economy', '11B', 5500.00,  'Confirmed'),
(512, 808, 1008, 18, 2, 'Economy', '11B', 6700.00,  'Confirmed'),
(513, 809, 1009, 2,  1, 'Economy', '7F',  4700.00,  'Confirmed'),
(514, 810, 1010, 11, 1, 'Business','3B',  16900.00, 'Confirmed'),
(515, 811, 1011, 12, 1, 'Economy', '25A', 5500.00,  'Confirmed'),
(516, 812, 1012, 17, 1, 'Economy', '10C', 4300.00,  'Confirmed'),
(517, 813, 1013, 12, 1, 'Economy', '6D',  5500.00,  'Confirmed'),
(518, 813, 1013, 18, 2, 'Economy', '6D',  6700.00,  'Confirmed'),
(519, 814, 1014, 18, 1, 'Economy', '20B', 6700.00,  'Confirmed'),
(520, 815, 1015, 14, 1, 'Economy', '8A',  4900.00,  'Confirmed'),
(521, 815, 1015, 18, 2, 'Economy', '8A',  6700.00,  'Confirmed'),
(522, 816, 1001, 1,  1, 'Economy', '15B', 4700.00,  'Confirmed'),
(523, 816, 1001, 5,  2, 'Economy', '15B', 6800.00,  'Confirmed'),
(524, 817, 1002, 8,  1, 'Economy', '28D', 5700.00,  'Cancelled'),
(525, 818, 1003, 3,  1, 'Business','1C',  18000.00, 'Confirmed'),
(526, 818, 1003, 20, 2, 'Business','1C',  20400.00, 'Confirmed'),
(527, 819, 1005, 14, 1, 'Economy', '12F', 4900.00,  'Confirmed'),
(528, 820, 1006, 10, 1, 'Economy', '33A', 6700.00,  'Confirmed'),
(529, 821, 1002, 8,  1, 'Economy', '9C',  5700.00,  'Confirmed'),
-- Booking 530 is Waitlisted for the same flight/leg/seat-type as
-- Booking 510 (Confirmed, seat 30E, Reservation 807) — cancel 510 to
-- see the trigger promote 530 into seat 30E automatically (see
-- README "Testing the waitlist trigger"). Fare is pre-quoted at
-- today's Route_Fare rate; it will apply once/if confirmed.
(530, 822, 1007, 1,  1, 'Economy', NULL,  4700.00,  'Waitlisted');


-- ============================================================
-- 13. LUGGAGE (30 records) — unchanged
-- ============================================================

INSERT INTO Luggage VALUES
(601, 501, 'TAG-AMD-001', 15.50),
(602, 501, 'TAG-AMD-002',  8.20),
(603, 503, 'TAG-BOM-001', 22.00),
(604, 504, 'TAG-AMD-003', 18.75),
(605, 506, 'TAG-DEL-001', 12.00),
(606, 508, 'TAG-BLR-001', 20.50),
(607, 509, 'TAG-DEL-002', 23.00),
(608, 510, 'TAG-AMD-004',  7.50),
(609, 511, 'TAG-BOM-002', 14.00),
(610, 513, 'TAG-STV-001',  9.30),
(611, 514, 'TAG-BLR-002', 21.00),
(612, 515, 'TAG-BOM-003', 11.50),
(613, 516, 'TAG-JAI-001',  6.80),
(614, 517, 'TAG-BOM-004', 17.20),
(615, 519, 'TAG-MAA-001', 25.00),
(616, 520, 'TAG-BLR-003', 13.60),
(617, 522, 'TAG-AMD-005', 10.40),
(618, 525, 'TAG-AMD-006', 24.50),
(619, 527, 'TAG-BLR-004', 16.80),
(620, 528, 'TAG-DEL-003', 19.00),
(621, 529, 'TAG-BOM-005',  8.70),
(622, 530, 'TAG-AMD-007', 12.30),
(623, 502, 'TAG-BOM-006', 14.90),
(624, 505, 'TAG-AMD-008', 11.10),
(625, 507, 'TAG-MAA-002', 20.00),
(626, 512, 'TAG-CCU-001',  9.80),
(627, 518, 'TAG-CCU-002', 22.50),
(628, 521, 'TAG-CCU-003', 15.00),
(629, 523, 'TAG-BLR-005',  7.20),
(630, 526, 'TAG-CCU-004', 23.80);


-- ============================================================
-- 14. PILOT_ASSIGN (30 records) — unchanged
-- ============================================================

INSERT INTO Pilot_Assign VALUES
-- Flight 1001 Leg 1 (AMD->BOM): Capt 201 + FO 204
(1001, 1,  1, 201),
(1001, 1,  1, 204),
-- Flight 1001 Leg 2 (BOM->BLR): Capt 202 + FO 205 (pilot changeover at BOM)
(1001, 5,  2, 202),
(1001, 5,  2, 205),
-- Flight 1002 Leg 1 (BOM->DEL): Capt 203 + FO 207
(1002, 8,  1, 203),
(1002, 8,  1, 207),
-- Flight 1003 Leg 1 (AMD->DEL): Capt 206 + FO 209
(1003, 3,  1, 206),
(1003, 3,  1, 209),
-- Flight 1003 Leg 2 (DEL->CCU): Capt 208 + FO 211 (changeover at DEL)
(1003, 20, 2, 208),
(1003, 20, 2, 211),
-- Flight 1004 Leg 1 (DEL->BLR): Capt 210 + FO 213
(1004, 10, 1, 210),
(1004, 10, 1, 213),
-- Flight 1004 Leg 2 (BLR->MAA): Capt 212 + FO 215 (changeover at BLR)
(1004, 14, 2, 212),
(1004, 14, 2, 215),
-- Flight 1005 Leg 1 (BLR->MAA): Capt 214 + FO 217
(1005, 14, 1, 214),
(1005, 14, 1, 217),
-- Flight 1006 Leg 1 (DEL->BLR): Capt 216 + FO 219
(1006, 10, 1, 216),
(1006, 10, 1, 219),
-- Flight 1007 Leg 1 (AMD->BOM): Capt 218 + FO 213
(1007, 1,  1, 218),
(1007, 1,  1, 213),
-- Flight 1008 Leg 1 (BOM->HYD): Capt 201 + FO 204
(1008, 12, 1, 201),
(1008, 12, 1, 204),
-- Flight 1008 Leg 2 (HYD->CCU): Capt 203 + FO 207
(1008, 18, 2, 203),
(1008, 18, 2, 207),
-- Flight 1010 Leg 1 (BLR->DEL): Capt 206 + FO 209
(1010, 11, 1, 206),
(1010, 11, 1, 209),
-- Intentional conflict for demo purposes: Pilot 203 is already on
-- Flight 1002 leg 8 (07:30-09:30 same day) and is also assigned here
-- to Flight 1006 leg 10 (06:30-08:20 same day) — the two overlap
-- 07:30-08:20, which the "pilots double-booked" audit query in the
-- README is designed to catch.
(1006, 10, 1, 203),
-- Flight 1013 Leg 1 (BOM->HYD): Capt 210 + FO 213
(1013, 12, 1, 210),
(1013, 12, 1, 213),
-- Flight 1014 Leg 1 (MAA->CCU): Capt 214 + FO 217
(1014, 18, 1, 214),
(1014, 18, 1, 217);


-- ============================================================
-- 15. CREW_ASSIGN (35 records) — unchanged
-- ============================================================

INSERT INTO Crew_Assign VALUES
-- Flight 1001 Leg 1
(1001, 1,  1, 301),
(1001, 1,  1, 303),
(1001, 1,  1, 306),
-- Flight 1001 Leg 2
(1001, 5,  2, 302),
(1001, 5,  2, 304),
(1001, 5,  2, 309),
-- Flight 1002 Leg 1
(1002, 8,  1, 307),
(1002, 8,  1, 310),
(1002, 8,  1, 312),
-- Flight 1003 Leg 1
(1003, 3,  1, 311),
(1003, 3,  1, 313),
(1003, 3,  1, 317),
-- Flight 1003 Leg 2
(1003, 20, 2, 315),
(1003, 20, 2, 316),
(1003, 20, 2, 320),
-- Flight 1004 Leg 1
(1004, 10, 1, 319),
(1004, 10, 1, 314),
(1004, 10, 1, 308),
-- Flight 1004 Leg 2
(1004, 14, 2, 301),
(1004, 14, 2, 305),
(1004, 14, 2, 318),
-- Flight 1005 Leg 1
(1005, 14, 1, 302),
(1005, 14, 1, 306),
-- Flight 1006 Leg 1
(1006, 10, 1, 307),
(1006, 10, 1, 310),
-- Flight 1007 Leg 1
(1007, 1,  1, 303),
(1007, 1,  1, 317),
-- Flight 1008 Leg 1
(1008, 12, 1, 311),
(1008, 12, 1, 313),
-- Flight 1008 Leg 2
(1008, 18, 2, 315),
(1008, 18, 2, 319),
-- Flight 1013 Leg 1
(1013, 12, 1, 304),
(1013, 12, 1, 309),
-- Flight 1014 Leg 1
(1014, 18, 1, 308),
(1014, 18, 1, 316);


-- ============================================================
-- 16. USES_RUNWAY (25 records) — unchanged
-- ============================================================

INSERT INTO Uses_Runway VALUES
(1001, 1,  1, 1, 1, 'Takeoff'),
(1001, 1,  1, 2, 1, 'Landing'),
(1001, 5,  2, 2, 2, 'Takeoff'),
(1001, 5,  2, 4, 1, 'Landing'),
(1002, 8,  1, 2, 2, 'Takeoff'),
(1002, 8,  1, 3, 1, 'Landing'),
(1003, 3,  1, 1, 1, 'Takeoff'),
(1003, 3,  1, 3, 2, 'Landing'),
(1003, 20, 2, 3, 1, 'Takeoff'),
(1003, 20, 2, 7, 1, 'Landing'),
(1004, 10, 1, 3, 3, 'Takeoff'),
(1004, 10, 1, 4, 1, 'Landing'),
(1004, 14, 2, 4, 2, 'Takeoff'),
(1004, 14, 2, 5, 1, 'Landing'),
(1005, 14, 1, 4, 1, 'Takeoff'),
(1005, 14, 1, 5, 1, 'Landing'),
(1006, 10, 1, 3, 1, 'Takeoff'),
(1006, 10, 1, 4, 2, 'Landing'),
(1007, 1,  1, 1, 2, 'Takeoff'),
(1007, 1,  1, 2, 1, 'Landing'),
(1008, 12, 1, 2, 1, 'Takeoff'),
(1008, 12, 1, 6, 1, 'Landing'),
(1008, 18, 2, 6, 2, 'Takeoff'),
(1008, 18, 2, 7, 2, 'Landing'),
(1010, 11, 1, 4, 1, 'Takeoff');


-- ============================================================
-- 17. USES_GATE (25 records) — unchanged
-- ============================================================

INSERT INTO Uses_Gate VALUES
(1001, 1,  1, 1, 1, 'Departure'),
(1001, 1,  1, 2, 1, 'Arrival'),
(1001, 5,  2, 2, 2, 'Departure'),
(1001, 5,  2, 4, 1, 'Arrival'),
(1002, 8,  1, 2, 3, 'Departure'),
(1002, 8,  1, 3, 1, 'Arrival'),
(1003, 3,  1, 1, 2, 'Departure'),
(1003, 3,  1, 3, 2, 'Arrival'),
(1003, 20, 2, 3, 3, 'Departure'),
(1003, 20, 2, 7, 1, 'Arrival'),
(1004, 10, 1, 3, 4, 'Departure'),
(1004, 10, 1, 4, 2, 'Arrival'),
(1004, 14, 2, 4, 1, 'Departure'),
(1004, 14, 2, 5, 1, 'Arrival'),
(1005, 14, 1, 4, 3, 'Departure'),
(1005, 14, 1, 5, 2, 'Arrival'),
(1006, 10, 1, 3, 5, 'Departure'),
(1006, 10, 1, 4, 2, 'Arrival'),
(1007, 1,  1, 1, 3, 'Departure'),
(1007, 1,  1, 2, 4, 'Arrival'),
(1008, 12, 1, 2, 1, 'Departure'),
(1008, 12, 1, 6, 1, 'Arrival'),
(1008, 18, 2, 6, 2, 'Departure'),
(1008, 18, 2, 7, 2, 'Arrival'),
(1010, 11, 1, 4, 1, 'Departure');


-- ============================================================
-- 18. MAINTENANCE (12 records) — Maintenance_Status
--     'In-Progress' -> 'InProgress' to match the new CHECK
--     (Maintenance_Status IN ('Scheduled','InProgress','Completed','Cancelled'))
-- ============================================================

INSERT INTO Maintenance VALUES
(701, 108, 'C-Check',          'Full structural inspection required. Corrosion found on left wing.',  'InProgress', '2024-05-15', '2024-05-15', NULL,         450000.00),
(702, 118, 'Engine Overhaul',  'Engine #2 vibration beyond limit. Full overhaul ordered.',            'InProgress', '2024-05-20', '2024-05-21', NULL,         890000.00),
(703, 101, 'A-Check',          'Routine A-check completed, all systems nominal.',                     'Completed',   '2024-04-01', '2024-04-01', '2024-04-02',  25000.00),
(704, 102, 'Line Maintenance', 'Tire replacement on main gear, brake pad inspection done.',           'Completed',   '2024-04-10', '2024-04-10', '2024-04-10',  12000.00),
(705, 103, 'B-Check',          'Avionics software update, APU inspection.',                          'Completed',   '2024-03-15', '2024-03-15', '2024-03-17',  75000.00),
(706, 107, 'A-Check',          'Routine check; cabin pressurization valve replaced.',                'Completed',   '2024-04-20', '2024-04-20', '2024-04-21',  30000.00),
(707, 110, 'Line Maintenance', 'Pre-flight snag: landing light replaced.',                           'Completed',   '2024-05-01', '2024-05-01', '2024-05-01',   5000.00),
(708, 115, 'A-Check',          'Routine A-check; hydraulic fluid top-up.',                           'Completed',   '2024-04-28', '2024-04-28', '2024-04-29',  22000.00),
(709, 113, 'C-Check',          'Scheduled 6-year major check; wing box inspection.',                 'Scheduled',   '2024-07-01', NULL,         NULL,          380000.00),
(710, 116, 'Line Maintenance', 'IFE system reboot required; seat 24C tray table broken.',            'Completed',   '2024-05-10', '2024-05-10', '2024-05-10',   8000.00),
(711, 119, 'A-Check',          'New aircraft first A-check after initial 800 flight hours.',         'Scheduled',   '2024-06-15', NULL,         NULL,           20000.00),
(712, 120, 'Line Maintenance', 'APU starter motor replaced before morning departure.',               'Completed',   '2024-05-30', '2024-05-30', '2024-05-30',  18000.00);


-- ============================================================
-- END OF INSERT SCRIPTS
-- ============================================================
