--=====================================================================================================================================================================================================================--
-- F1 PERFORMANCE ANALYSIS - 2025 CHINESE GP
--=====================================================================================================================================================================================================================--

USE F1_ChineseGP_2025;

-- drop tables if exists
DROP TABLE IF EXISTS results;
DROP TABLE IF EXISTS pit_stops;
DROP TABLE IF EXISTS lap_times;
DROP TABLE IF EXISTS drivers;


----------------------- SCHEMA CREATION -----------------------

-- CREATED TABLES THEM IMPORTED FROM DATABASE ON KAGGLE, THEN WE CLEANED AND ANALYZED THE DATA.
-- VARCHAR- OK for Import, Bad for Analysis. We’ll fix this after importing.
/*
PRIMARY KEY → unique driver
UNIQUE → no duplicate codes
CHECK → no invalid numbers
*/
CREATE TABLE drivers (
    driver_number VARCHAR(5) UNIQUE NOT NULL,         -- Car number
    driver_id VARCHAR(50) PRIMARY KEY,         -- Unique driver
    abbreviation VARCHAR(5) UNIQUE NOT NULL,   -- VER, HAM, etc
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    team_name VARCHAR(50) NOT NULL
);

/*
We store raw + converted time.
Raw is for display, converted is for calculations.
We also store sector times for more detailed analysis.
*/
CREATE TABLE lap_times (
    abbreviation VARCHAR(5) NOT NULL,
    lap_number VARCHAR(5) NOT NULL,
    lap_time_raw VARCHAR(50) NOT NULL,
    position_at_lap VARCHAR(5) NOT NULL,
    cumulative_time_raw VARCHAR(50),

    sector1_raw VARCHAR(50),
    sector2_raw VARCHAR(50),
    sector3_raw VARCHAR(50),

    CONSTRAINT fk_lap_driver
        FOREIGN KEY (abbreviation)
        REFERENCES drivers(abbreviation)
);

SELECT * FROM drivers; 

SELECT * FROM lap_times; 

/*
Pit stops are crucial for strategy.
We track the time spent in the pit and the lap on which it occurred.
This helps analyze how pit stops affected race performance.
*/
CREATE TABLE pit_stops (
    abbreviation VARCHAR(5) NOT NULL,
    lap_number VARCHAR(5) NOT NULL,

    pit_out_time_raw VARCHAR(50),
    pit_in_time_raw VARCHAR(50), --Allows NULL for incomplete data.

    -- pit_duration_ms VARCHAR(50), We’ll convert these after importing to avoid import errors.

    CONSTRAINT fk_pit_driver
        FOREIGN KEY (abbreviation)
        REFERENCES drivers(abbreviation)
); 

CREATE TABLE results (
    driver_id VARCHAR(50) NOT NULL,
    abbreviation VARCHAR(5) NOT NULL,
    full_name VARCHAR(100),
    team_name VARCHAR(50),

    points VARCHAR(10) NOT NULL,
    final_position VARCHAR(5) NOT NULL,

    CONSTRAINT fk_result_driver
        FOREIGN KEY (driver_id)
        REFERENCES drivers(driver_id)
); 

SELECT * FROM pit_stops; 

SELECT * FROM results; 

-- Now we import the data from CSV files. We use BULK INSERT for efficient loading.
BULK INSERT drivers
FROM '/var/opt/mssql/data/drivers.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);

BULK INSERT lap_times
FROM '/var/opt/mssql/data/lap_times.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);

BULK INSERT pit_stops
FROM '/var/opt/mssql/data/pit_stops.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);

BULK INSERT results
FROM '/var/opt/mssql/data/results.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);

SELECT * FROM drivers;

SELECT * FROM lap_times;

SELECT * FROM pit_stops;

SELECT * FROM results;


----------------------- DATA CLEANING -----------------------


-- Null checks
SELECT COUNT(*) FROM lap_times WHERE lap_time_raw IS NULL; -- counting null values in lap_time_raw column
SELECT COUNT(*) FROM drivers WHERE abbreviation IS NULL; -- counting null values in abbreviation column of drivers table

-- Check bad values
SELECT * FROM lap_times WHERE lap_number NOT LIKE '[0-9]%'; -- checking for lap numbers that are not numeric

-- Add new columns for converted time values in milliseconds
ALTER TABLE lap_times
ADD lap_time_ms BIGINT;

ALTER TABLE lap_times
ADD sector1_ms BIGINT,
    sector2_ms BIGINT,
    sector3_ms BIGINT;

-- Update lap_times with converted time values
UPDATE lap_times
SET lap_time_ms =  -- it shows error because of the format of lap_time_raw, we need to convert it to a time format first
    DATEDIFF(
        MILLISECOND,
        '00:00:00.000',
        TRY_CONVERT(
            TIME(3),
            LEFT(REPLACE(lap_time_raw, '0 days ', ''), 12)
        )
    );

-- Update sector times with converted values
UPDATE lap_times
SET sector1_ms =
    DATEDIFF(
        MILLISECOND,
        '00:00:00.000',
        TRY_CONVERT(
            TIME(3),
            LEFT(REPLACE(sector1_raw, '0 days ', ''), 12)
        )
    ),
    sector2_ms =
    DATEDIFF(
        MILLISECOND,
        '00:00:00.000',
        TRY_CONVERT(
            TIME(3),
            LEFT(REPLACE(sector2_raw, '0 days ', ''), 12)
        )
    ),
    sector3_ms =
    DATEDIFF(
        MILLISECOND,
        '00:00:00.000',
        TRY_CONVERT(
            TIME(3),
            LEFT(REPLACE(sector3_raw, '0 days ', ''), 12)
        )
    );

SELECT * FROM lap_times;

/*
before analyzing the impact of pit stops on lap times,
we convert the column names to correct data types for easier calculations.
*/
ALTER TABLE lap_times
ALTER COLUMN lap_number DECIMAL(5,1) NOT NULL;

ALTER TABLE pit_stops
ALTER COLUMN lap_number DECIMAL(5,1) NOT NULL;


-- adding remaining constarints to ensure data integrity

-- Add CHECK Constraints (Prevent Garbage Data)
-- Lap numbers should be between 1 and 56 (max laps)
ALTER TABLE lap_times
ADD CONSTRAINT chk_lap_positive
CHECK (lap_number BETWEEN 1 AND 56);

-- Pit stop lap numbers should also be valid
ALTER TABLE lap_times
ALTER COLUMN position_at_lap DECIMAL(5,1);
ALTER TABLE lap_times
ADD CONSTRAINT chk_position_valid
CHECK (position_at_lap BETWEEN 1 AND 20);

-- Points should be non-negative and realistic
ALTER TABLE results
ALTER COLUMN points DECIMAL(5,1);
ALTER TABLE results
ADD CONSTRAINT chk_points_positive
CHECK (points >= 0);

-- Final position should be between 1 and 20
ALTER TABLE results
ALTER COLUMN final_position DECIMAL(5,1);
ALTER TABLE results
ADD CONSTRAINT chk_final_position_valid
CHECK (final_position BETWEEN 1 AND 20);

-- also check for lap numbers + abbreviations combo repeating(both columns should be NOT NULL)
-- Add Composite PRIMARY KEYS (Prevent Duplicates)
ALTER TABLE lap_times
ADD CONSTRAINT pk_lap_times
PRIMARY KEY (abbreviation, lap_number); -- one row per lap per driver

ALTER TABLE pit_stops
ADD CONSTRAINT pk_pit_stops
PRIMARY KEY (abbreviation, lap_number); -- one pit stop per lap per driver


----------------------- QUERY OPTIMIZATION -----------------------


-- Add Indexes (Performance Boost)
-- as your data grows, joins slow down. Indexes fix that.
-- for joins
CREATE INDEX idx_lap_abbreviation ON lap_times(abbreviation, lap_number);
CREATE INDEX idx_pit_abbreviation ON pit_stops(abbreviation, lap_number);
/*
CREATE INDEX idx_lap_abbrev_only
ON lap_times(abbreviation);
-- Only add this(narrower index) if your dataset is very large and if you frequently do: GROUP BY abbreviation
*/
-- for analysis
-- CREATE INDEX idx_lap_time_ms ON lap_times(lap_time_ms); -- normal index
/* BETTER WAY: Advanced Indexing with INCLUDE
- SQL doesn’t need to go back to table
- Everything is inside index
- Much faster aggregations
*/
CREATE INDEX idx_lap_abbrev_cover
ON lap_times(abbreviation)
INCLUDE (lap_time_ms);


----------------------- 1 - IMPACT OF PIT STOPS ON LAP TIMES -----------------------


-- Check for outliers in lap times(very slow due to incidents or very fast due to errors in data)
-- Your lap times are within realistic F1 range (85 sec – 120 sec)
SELECT *
FROM lap_times
WHERE lap_time_ms < 85000
   OR lap_time_ms > 120000;

-- Since you don’t have pit-in time, we measure: Lap BEFORE pit vs Lap AFTER pit
SELECT
    -- From drivers for better readability
    d.abbreviation,
    d.full_name,
    d.team_name,
    -- From pit stops: pit lap
    p.lap_number AS pit_lap,
    -- From lap times (converted to seconds)
    b.lap_time_ms / 1000.0 AS before_pit_sec,
    a.lap_time_ms / 1000.0 AS after_pit_sec,
    -- Delta = after lap - before lap (in seconds)
    (a.lap_time_ms - b.lap_time_ms) / 1000.0 AS delta_sec
    -- Positive → lost time
    -- Negative → gained time (successful undercut)
FROM pit_stops p   -- Start from pit stops (where strategy happens)

JOIN lap_times b
    ON p.abbreviation = b.abbreviation
   AND p.lap_number - 1 = b.lap_number

JOIN lap_times a
    ON p.abbreviation = a.abbreviation
   AND p.lap_number + 1 = a.lap_number

JOIN drivers d
    ON d.abbreviation = p.abbreviation
-- Biggest time loss first, biggest gain last
ORDER BY delta_sec DESC;

/*
Look specifically at:
- Is before_sec very high (110–130)?
- Is after_sec normal (90–100)?
If yes → safety car or degradation effect.

If:
- Everyone pitted during heavy degradation phase
- Everyone gained pace on fresh tyres
- No safety car after stop
Then yes:
All drivers could show negative delta.
That means:
- Strong undercut phase
- High tyre degradation track
That’s actually realistic in places like China (depending on tyre compounds).

Better Way-
Compare: Average of 3 laps before pit vs Average of 3 laps after pit
*/

-- This smooths out anomalies and gives a clearer picture of the pit stop impact.
SELECT
    d.abbreviation,
    d.full_name,
    d.team_name,
    p.lap_number AS pit_lap,
    -- Average of 3 laps BEFORE pit
    AVG(b.lap_time_ms)/1000.0 AS avg_before_sec,
    -- Average of 3 laps AFTER pit
    AVG(a.lap_time_ms)/1000.0 AS avg_after_sec,
    -- Net pit cycle impact
    (AVG(a.lap_time_ms) - AVG(b.lap_time_ms))/1000.0 AS delta_sec
FROM pit_stops p

JOIN lap_times b
 ON p.abbreviation = b.abbreviation
 AND b.lap_number BETWEEN p.lap_number-3 AND p.lap_number-1

JOIN lap_times a
 ON p.abbreviation = a.abbreviation
 AND a.lap_number BETWEEN p.lap_number+1 AND p.lap_number+3
JOIN drivers d
 ON d.abbreviation = p.abbreviation
-- Exclude early and late stops
WHERE p.lap_number BETWEEN 4 AND 53
GROUP BY
    d.abbreviation,
    d.full_name,
    d.team_name,
    p.lap_number
-- Only keep pit stops where we truly found 3 unique laps before AND after (avoids BOR pit lap at 2)
HAVING
 COUNT(DISTINCT b.lap_number) = 3
 AND COUNT(DISTINCT a.lap_number) = 3
ORDER BY delta_sec DESC;

/*
The above query is faster than the below one - 
- pit_stops is very small (maybe ~20 rows).
- The filter p.lap_number BETWEEN 4 AND 53 removes early/late stops immediately.
- indexes on lap_times(abbreviation, lap_number) to quickly find the 3 laps before and after.
So SQL only scans a few lap rows per pit stop, not the entire lap table.
*/

-- pit stops analysis using CTEs for better readability (but it may be slower than the above query due to multiple scans of lap_times)
WITH filtered_pits AS (
    SELECT *
    FROM pit_stops
    WHERE lap_number BETWEEN 4 AND 53
),
lap_before AS (
    SELECT
        abbreviation,
        lap_number,
        lap_time_ms
    FROM lap_times
),
lap_after AS (
    SELECT
        abbreviation,
        lap_number,
        lap_time_ms
    FROM lap_times
)
SELECT
    d.abbreviation,
    d.full_name,
    d.team_name,
    p.lap_number AS pit_lap,
    AVG(b.lap_time_ms)/1000.0 AS avg_before_sec,
    AVG(a.lap_time_ms)/1000.0 AS avg_after_sec,
    (AVG(a.lap_time_ms) - AVG(b.lap_time_ms))/1000.0 AS delta_sec
FROM filtered_pits p
JOIN lap_before b
 ON p.abbreviation = b.abbreviation
 AND b.lap_number BETWEEN p.lap_number-3 AND p.lap_number-1
JOIN lap_after a
 ON p.abbreviation = a.abbreviation
 AND a.lap_number BETWEEN p.lap_number+1 AND p.lap_number+3
JOIN drivers d
 ON d.abbreviation = p.abbreviation
GROUP BY
    d.abbreviation,
    d.full_name,
    d.team_name,
    p.lap_number
HAVING
 COUNT(DISTINCT b.lap_number) = 3
 AND COUNT(DISTINCT a.lap_number) = 3
ORDER BY delta_sec DESC;


-- check which stops were excluded due to not having 3 laps before or after
SELECT
    abbreviation,
    lap_number
FROM pit_stops
WHERE lap_number < 4
   OR lap_number > 53
ORDER BY lap_number;


----------------------- 2 -RACE PACE ANALYSIS -----------------------


-- View for clean laps(All laps except pit lap)
DROP VIEW IF EXISTS v_clean_laps; 
GO
CREATE VIEW v_clean_laps AS
SELECT l.*
FROM lap_times l
LEFT JOIN pit_stops p
 ON l.abbreviation=p.abbreviation
 AND l.lap_number=p.lap_number
WHERE p.abbreviation IS NULL;
GO
select * from v_clean_laps; 

/*
Best race pace = Lowest average clean lap time (excluding pit laps).
This shows who had the best race pace, using average lap times excluding pit laps.
Drivers with many pit stops or DNF must have fewer clean laps,
so we set a condition to include who completed most of the laps.
For fastest single lap, we change to MIN(c.lap_time_ms)/1000.0 AS best_lap_sec. 
*/
DECLARE @total_laps INT = 56; -- total laps
SELECT
 d.abbreviation,
 d.full_name,
 d.team_name,
 COUNT(*) AS total_clean_laps, -- how many clean laps each driver completed
 AVG(c.lap_time_ms)/1000.0 AS avg_lap_sec -- average lap time in seconds (converted from ms)
FROM v_clean_laps c
JOIN drivers d
 ON c.abbreviation = d.abbreviation
GROUP BY
 d.abbreviation,
 d.full_name,
 d.team_name
HAVING COUNT(*) >= @total_laps - 10 -- only consider drivers with at least 46 clean laps (exclude those with many pit stops or retirements)
ORDER BY avg_lap_sec;

/*
The above query is slower than the below one because:
Original workflow: 1100 lap rows -> join drivers -> group by driver
Optimized workflow: 1100 lap rows -> group by driver -> 20 rows -> join drivers
*/

-- Optimized query without CTEs (faster)
WITH clean_laps AS (
    SELECT
        l.abbreviation,
        l.lap_time_ms
    FROM lap_times l
    LEFT JOIN pit_stops p
      ON l.abbreviation = p.abbreviation
     AND l.lap_number = p.lap_number
    WHERE p.abbreviation IS NULL
),
driver_pace AS (
    SELECT
        abbreviation,
        COUNT(*) AS total_clean_laps,
        AVG(lap_time_ms) AS avg_lap_ms
    FROM clean_laps
    GROUP BY abbreviation
)
SELECT
    d.abbreviation,
    d.full_name,
    d.team_name,
    p.total_clean_laps,
    p.avg_lap_ms/1000.0 AS avg_lap_sec
FROM driver_pace p
JOIN drivers d
 ON p.abbreviation = d.abbreviation
WHERE p.total_clean_laps >= 46
ORDER BY avg_lap_sec;


----------------------- 3 - CONSISTENCY ANALYSIS -----------------------


/*
Consistency = Lowest standard deviation of lap times (excluding pit laps).
This shows which driver had the most consistent pace throughout the race.
*/
DECLARE @total_laps INT = 56; -- total laps
SELECT
 d.abbreviation,
 d.full_name,
 d.team_name,
 COUNT(*) AS total_clean_laps,
 STDEV(c.lap_time_ms)/1000.0 AS consistency_sec -- standard deviation of lap times in seconds
FROM v_clean_laps c
JOIN drivers d
 ON c.abbreviation = d.abbreviation
GROUP BY
 d.abbreviation,
 d.full_name,
 d.team_name
HAVING COUNT(*) >= @total_laps - 10 -- only consider drivers with at least 46 clean laps
ORDER BY consistency_sec; -- lowest std dev = most consistent


----------------------- 4 - POSITION CHANGES ANALYSIS -----------------------


/*
Position changes = Difference between starting position and final position.
This shows which drivers gained or lost the most positions during the race.
We can calculate starting position from the first lap’s position and final position from the results table.
Avoid correlated subqueries and use joins with views to improve query performance and maintainability.
*/
DROP VIEW IF EXISTS v_start_position; 
GO
CREATE VIEW v_start_position AS -- view to get starting positions of drivers
SELECT
 abbreviation,
 position_at_lap AS starting_position
FROM lap_times
WHERE lap_number = 1; -- first lap position = starting position
GO
select * from v_start_position;
-- Now we can join this view with results to calculate position changes.
SELECT
 d.abbreviation,
 d.full_name,
 d.team_name,
 s.starting_position,
 r.final_position,
 (s.starting_position - r.final_position) AS position_change -- positive = gained positions, negative = lost positions
FROM drivers d
JOIN v_start_position s
 ON d.abbreviation = s.abbreviation
JOIN results r
 ON d.driver_id = r.driver_id
ORDER BY position_change DESC; -- biggest gain first


----------------------- SCHEMA AND CLEANING FOR OVERALL RACE SUMMARY -----------------------


----create table for teams(Removes Redundancy)
DROP TABLE IF EXISTS teams; -- drop teams table if it exists

CREATE TABLE teams(
    team_id INT IDENTITY PRIMARY KEY,
    team_name VARCHAR(50) UNIQUE NOT NULL
); 

INSERT INTO teams (team_name)
SELECT DISTINCT team_name
FROM drivers; --populate teams table with unique team names from drivers table

SELECT * FROM teams;

--add team_id column to drivers table(temporary nullable because existing rows don’t have values.)
ALTER TABLE drivers
ADD team_id INT;

UPDATE d
SET d.team_id = t.team_id
FROM drivers d
JOIN teams t
 ON d.team_name = t.team_name; --update team_id in drivers table based on matching

ALTER TABLE drivers
ALTER COLUMN team_id INT NOT NULL; --make team_id NOT NULL as every driver must belong to a team

ALTER TABLE drivers
ADD CONSTRAINT fk_driver_team
FOREIGN KEY (team_id)
REFERENCES teams(team_id); --add foreign key constraint(team_id) to ensure referential integrity between drivers and teams tables

-- OPTIONAL - check when tables are fully normalized and repeated TEAM_NAME then we can remove the redundant column from drivers table


/*
OPTIONAL - Create Races Table (Important for Scalability).
Then add race_id to lap_times and pit_stops.
This makes your database scalable for: various seasons and multiple circuits.

CREATE TABLE races (
    race_id INT IDENTITY PRIMARY KEY,
    race_name VARCHAR(100),
    race_date DATE
); --create table for races
SELECT * FROM races; --view races table
*/


-- check and remove: Pit laps, Extremely slow laps, Formation lap
SELECT *
FROM lap_times l
LEFT JOIN pit_stops p 
    ON l.abbreviation = p.abbreviation 
    AND l.lap_number = p.lap_number
WHERE p.lap_number IS NULL
AND l.lap_time_ms BETWEEN 85000 AND 120000;


----------------------- RACE SUMMARY -----------------------


-- Create race_summary view to analyze the metrics without pit laps and outliers.
/*
| Metric          | Why It’s Important         |
| --------------- | -------------------------- |
| avg_race_pace   | Race engineer’s key metric |
| consistency     | Tyre management indicator  |
| fastest_lap     | Peak performance           |
| total_pit_stops | Strategy evaluation        |
*/
DROP VIEW IF EXISTS race_summary; 
GO
CREATE VIEW race_summary AS
SELECT 
    d.full_name,
    d.abbreviation,
    t.team_name,
    COUNT(CASE 
        WHEN l.lap_time_ms BETWEEN 85000 AND 120000 -- only count realistic lap times
        THEN 1 
    END) AS clean_laps, -- count of clean laps for each driver
    
    AVG(CASE 
        WHEN l.lap_time_ms BETWEEN 85000 AND 120000 -- only average realistic lap times
        THEN l.lap_time_ms/1000.0 
    END) AS avg_race_pace_sec, 

    STDEV(CASE 
        WHEN l.lap_time_ms BETWEEN 85000 AND 120000 -- only calculate consistency for realistic lap times
        THEN l.lap_time_ms/1000.0 
    END) AS consistency_sec, 

    MIN(CASE 
        WHEN l.lap_time_ms BETWEEN 85000 AND 120000 -- NOTE: in clean data, fastest lap will naturally be a racing lap, we use the condition to exclude any outliers that might be faster than realistic lap times (especially in kaggle data).
        THEN l.lap_time_ms/1000.0 -- NOTE: you used same for above, if this does not use same rule, then your metrics are inconsistent.
    END) AS fastest_lap_sec, -- fastest lap in seconds

    COUNT(DISTINCT p.lap_number) AS total_pit_stops -- count unique pit stop laps

FROM lap_times l
JOIN drivers d ON l.abbreviation = d.abbreviation
JOIN teams t ON d.team_id = t.team_id
LEFT JOIN pit_stops p 
    ON l.abbreviation = p.abbreviation 
    AND l.lap_number = p.lap_number
GROUP BY d.full_name, d.abbreviation, t.team_name;
GO
SELECT * FROM race_summary; 

/*
Because your dataset is small:
- SQL Server already handles the CASE efficiently.
- So performance difference will be very small.
*/

-- same analysis with subqueries instead of CASE statements (slightly cleaner logically, better for large data)
DROP VIEW IF EXISTS race_summary;
GO
CREATE VIEW race_summary AS
SELECT 
    d.full_name,
    d.abbreviation,
    t.team_name,
    COUNT(*) AS clean_laps,
    AVG(l.lap_time_ms)/1000.0 AS avg_race_pace_sec,
    STDEV(l.lap_time_ms)/1000.0 AS consistency_sec,
    MIN(l.lap_time_ms)/1000.0 AS fastest_lap_sec,
    COUNT(DISTINCT p.lap_number) AS total_pit_stops
FROM (
        SELECT *
        FROM lap_times
        WHERE lap_time_ms BETWEEN 85000 AND 120000 -- TSU will show only 2 pit laps only because of the condition(total pit stops = 3)
     ) l
JOIN drivers d
  ON l.abbreviation = d.abbreviation
JOIN teams t
  ON d.team_id = t.team_id
LEFT JOIN pit_stops p
  ON l.abbreviation = p.abbreviation
 AND l.lap_number = p.lap_number
GROUP BY
 d.full_name,
 d.abbreviation,
 t.team_name;
GO
SELECT * FROM race_summary; 


----------------------- RANKED RACE SUMMARY -----------------------


-- Now we can rank drivers based on their average race pace using a window function.
DROP VIEW IF EXISTS ranked_race_summary; 
GO
CREATE VIEW ranked_race_summary AS
SELECT 
    rs.full_name,
    rs.abbreviation,
    rs.team_name,
    rs.clean_laps,
    rs.avg_race_pace_sec,
    rs.consistency_sec,
    rs.fastest_lap_sec,
    rs.total_pit_stops,
    RANK() OVER (ORDER BY rs.avg_race_pace_sec ASC) AS pace_rank -- rank drivers based on average race pace (lower is better)
FROM race_summary rs;
GO
SELECT * FROM  ranked_race_summary; 
/*
window function RANK() OVER (...)- calculate rank without grouping or removing rows, it just adds a new column.
If Two Drivers Have Same Pace: then they get same rank, next rank is skipped (1, 1, 3).
OVER() Instead of GROUP BY: if you used GROUP BY, you would lose row details and can’t calculate rank across the entire dataset.
*/


----------------------- RESULTS SUMMARY -----------------------

/*
- I organized and cleaned the race data so the analysis would be correct and trustworthy.
- I removed pit-stop laps so that average speed and consistency were calculated fairly.
- PIA was the fastest driver on average, with an average lap time of 97.05 seconds over 55 clean laps.
- PIA was also the most consistent driver, meaning his lap times did not change much during the race.
- To study pit stops, I compared the average of three laps before and after each stop, so traffic and cold tyres did not affect the result too much.
- I checked how many places each driver gained or lost by comparing their first-lap position with their final result.
- Drivers who were more consistent and had good pit strategies usually finished higher in the race.
- Overall, I built to clean data, convert time formats, and analyze driver performance efficiently.
*/
