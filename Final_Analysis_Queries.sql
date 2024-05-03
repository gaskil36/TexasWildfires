-- Create the initial database
CREATE DATABASE TEXASWILDFIRES;

-- Connect to the database
\c texaswildfires;

-- Create spatial extensions
CREATE EXTENSION POSTGIS;
CREATE EXTENSION POSTGIS_RASTER;

-- Change directory
\cd /home/bengaskill12

-- Import each .sql file into the database
\i texas_prefire.sql
\i texas_postfire.sql
\i texas_nbr_prefire.sql
\i texas_nbr_postfire.sql
\i texas_evi_prefire.sql
\i texas_evi_postfire.sql
\i texas_DNBR.sql
\i texas_BurntClassesClipped.sql
\i texas_burnSeverityClipped.sql
\i classified_landcover_clipped.sql
\i population_first.sql
\i population_second.sql
\i population_third.sql

-- Join population tables
CREATE TABLE population_all AS
SELECT * FROM population_first
UNION ALL
SELECT * FROM population_second
UNION ALL
SELECT * FROM population_third;

-- Validate new TABLE
SELECT COUNT(name)
FROM population_all;

-- Filter population fields
CREATE TABLE population_filtered AS
SELECT gid, geoid, county_nam AS county, 
	   state_name AS state, p0010001 AS total_population, 
	   h0010001 AS total_housing_units, arealand AS area_land, 
	   areawatr AS area_water, shape_leng, shape_area, geom
FROM population_all;

-- Perform summary analysis on filtered population dataset
CREATE TABLE population_by_county AS
SELECT
  county,
  state,
  COUNT(DISTINCT geoid) AS total_blocks,
  SUM(total_population) AS total_population,
  SUM(total_housing_units) AS total_housing_units,
  -- area_land, area_water are considered varchars. I had to cast to an integer type
  SUM(CAST(area_land AS INT)) AS area_land,
  SUM(CAST(area_water AS INT)) AS area_water,
  SUM(shape_leng) AS shape_leng,
  SUM(shape_area) AS shape_area,
FROM
  population_filtered
GROUP BY
  state, county;

-- Get the total area of counties in the study area for reference
SELECT SUM(shape_area) 
FROM population_by_county 
LIMIT 1000;

-------------------------------------------------------------------------
-- After converting texas_BurntClassesClipped to a 30 x 30 tiled raster -
-- I could run spatial queries to get the total area burned and unburned-
-------------------------------------------------------------------------
-- Create a table for batch processing of pixels, 15 million at a time.
CREATE TABLE texas_burnt_pixel_points (
    pixel_value DECIMAL
);
-- Batch
DO $$
DECLARE
    batch_size INT := 15000000;
    total_pixels INT;
    offsets INT := 0;
BEGIN
    -- Count pixels
    SELECT COUNT(*) INTO total_pixels FROM texas_burntclassesclipped_rast;
    
    WHILE offsets < total_pixels LOOP
        INSERT INTO texas_burnt_pixel_points (pixel_value)
        SELECT (ST_PixelAsPoints(rast)).val AS pixel_value
        FROM texas_burntclassesclipped_rast
        OFFSET offsets ROWS FETCH NEXT LEAST(batch_size, total_pixels - offsets) ROWS ONLY;
        
        offsets := offsets + batch_size;
    END LOOP;
END $$;

-- Get the total number of tiles in the raster
SELECT COUNT(pixel_value) AS pixel_count
FROM texas_burnt_pixel_points;

-- Get the total area (sq km) of the raster (CROSS CHECKED IN QGIS) (36743.02775699519 sq km)
SELECT SUM(ST_Area(rast::geometry::geography)) / 1000000.0 AS total_area_sq_km
FROM texas_burntclassesclipped_rast;

-- Get the total number of burnt 1 and unburnt 0 pixels (CROSS CHECKED IN QGIS TO CONFIRM 1 IS BURNT AND O IS UNBURNT) (56,363)
CREATE TABLE texas_burnt_pixel_summary AS
SELECT pixel_value, COUNT(*) AS count
FROM texas_burnt_pixel_points
GROUP BY pixel_value;

-- 56,363 records in table * (30x30) for each tile = 50,726,700 (matches the qgis expected total pixels)
-- Calculate the total number of pixels
SELECT COUNT(*) * (30 * 30) AS total_pixels
FROM texas_burnt_pixel_points;

-- Get total pixels, use to calculate area per pixel, total area unburned, and total area burned
CREATE TABLE binary_results AS
WITH pixel_summary AS (
    SELECT 
        COUNT(*) * (30 * 30) AS total_pixels
    FROM texas_burnt_pixel_points
)
SELECT 
	-- Area per pixel should be 36743.02775699519 sq km  / 50,726,700 = 7.243330978950965e-4 sq km
    SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS area_per_pixel_sq_km,
	-- Calculate the total area unburned
	-- 46599 records in the table * (30x30) for each tile = (41,939,100 pixels * area per pixel) = 30377.87822593224162315 sq km
	(SELECT count FROM texas_burnt_pixel_summary WHERE pixel_value = 0) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_unburned_sq_km,
	-- Calculate the total area burned
	-- 9764 records in the table * (30x30) for each tile = (8,787,600 pixels * area per pixel) = 6365.1495310629500034 sq km
	(SELECT count FROM texas_burnt_pixel_summary WHERE pixel_value = 1) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_burned_sq_km
FROM texas_burntclassesclipped_rast, pixel_summary
GROUP BY total_pixels;

------------------------------------------------------------------------------
-- After converting texas_burnseverityclipped_rast to a 30 x 30 tiled raster -
-- I could run spatial queries to get the total area burned by severity      -
------------------------------------------------------------------------------
-- Create a table for batch processing of pixels, 15 million at a time.
CREATE TABLE texas_burnt_severity_pixel_points (
    pixel_value DECIMAL
);
-- Batch
DO $$
DECLARE
    batch_size INT := 15000000;
    total_pixels INT;
    offsets INT := 0;
BEGIN
    -- Count pixels
    SELECT COUNT(*) INTO total_pixels FROM texas_burnseverityclipped_rast;
    
    WHILE offsets < total_pixels LOOP
        INSERT INTO texas_burnt_severity_pixel_points (pixel_value)
        SELECT (ST_PixelAsPoints(rast)).val AS pixel_value
        FROM texas_burnseverityclipped_rast
        OFFSET offsets ROWS FETCH NEXT LEAST(batch_size, total_pixels - offsets) ROWS ONLY;
        
        offsets := offsets + batch_size;
    END LOOP;
END $$;

CREATE TABLE texas_burn_severity_pixel_summary AS
SELECT pixel_value, COUNT(*) AS count
FROM texas_burnt_severity_pixel_points
GROUP BY pixel_value;

CREATE TABLE severity_results AS
WITH pixel_summary AS (
    SELECT 
        COUNT(*) * (30 * 30) AS total_pixels
    FROM texas_burnt_severity_pixel_points
)
SELECT 
    SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS area_per_pixel_sq_km,
	(SELECT count FROM texas_burn_severity_pixel_summary WHERE pixel_value = 0) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_regrowth_sq_km,
	(SELECT count FROM texas_burn_severity_pixel_summary WHERE pixel_value = 1) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_unburned_km,
  (SELECT count FROM texas_burn_severity_pixel_summary WHERE pixel_value = 2) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_burned_low_sq_km,
	(SELECT count FROM texas_burn_severity_pixel_summary WHERE pixel_value = 3) * (30 * 30) * SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_burned_moderate_sq_km
FROM texas_burntclassesclipped_rast, pixel_summary
GROUP BY total_pixels;

----------------------------------------------
-- Working with the CONUS Landcover dataset --
----------------------------------------------

-- Get the pixel values and counts from the raster
CREATE TABLE landcover_raw_values AS
SELECT (ST_ValueCount(rast)).value AS pixel_value,
       (ST_ValueCount(rast)).count AS pixel_count
FROM classified_landcover_clipped_rast;

-- Create a new table to summarize landcover
CREATE TABLE landcover_summary (
    landcover_type TEXT,
    pixel_count INTEGER
);

INSERT INTO landcover_summary (landcover_type, pixel_count)
SELECT 
    CASE
        WHEN pixel_value = 11 THEN 'Open Water'
        WHEN pixel_value = 12 THEN 'Perennial Ice/Snow'
        WHEN pixel_value = 21 THEN 'Developed, Open Space'
        WHEN pixel_value = 22 THEN 'Developed, Low Intensity'
        WHEN pixel_value = 23 THEN 'Developed, Medium Intensity'
        WHEN pixel_value = 24 THEN 'Developed High Intensity'
        WHEN pixel_value = 31 THEN 'Barren Land (Rock/Sand/Clay)'
        WHEN pixel_value = 41 THEN 'Deciduous Forest'
        WHEN pixel_value = 42 THEN 'Evergreen Forest'
        WHEN pixel_value = 43 THEN 'Mixed Forest'
        WHEN pixel_value = 51 THEN 'Dwarf Scrub'
        WHEN pixel_value = 52 THEN 'Shrub/Scrub'
        WHEN pixel_value = 71 THEN 'Grassland/Herbaceous'
        WHEN pixel_value = 72 THEN 'Sedge/Herbaceous'
        WHEN pixel_value = 73 THEN 'Lichens'
        WHEN pixel_value = 74 THEN 'Moss'
        WHEN pixel_value = 81 THEN 'Pasture/Hay'
        WHEN pixel_value = 82 THEN 'Cultivated Crops'
        WHEN pixel_value = 90 THEN 'Woody Wetlands'
        WHEN pixel_value = 95 THEN 'Emergent Herbaceous Wetlands'
        ELSE 'Other'
    END AS landcover_type,
    pixel_count
FROM 
    (SELECT 
        pixel_value, 
        pixel_count
    FROM 
        landcover_raw_values
    ) AS v;

-- Select from the new table
SELECT * 
FROM landcover_summary
ORDER BY pixel_count DESC;

-- Calculate landcover area
-- Get total pixels, use to calculate area per pixel, total area unburned, and total area burned
CREATE TABLE landcover_area AS
WITH pixel_summary AS (
    SELECT SUM(pixel_count) as total_pixels 
    FROM landcover_summary
)
SELECT 
	-- Area per pixel should be 36743.02775699519 sq km  / 41044500 = 0.0008951997894236 sq km
    SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS area_per_pixel_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 11)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Open_Water_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 21)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Developed_Open_Space_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 22)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Developed_Low_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 23)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Developed_Medium_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 24)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Developed_High_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 31)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Barren_Land_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 41)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Deciduous_Forest_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 42)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Evergreen_Forest_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 43)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Mixed_Forest_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 52)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Shrub_Scrub_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 71)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Grassland_Herbaceous_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 81)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Pasture_Hay_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 82)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Cultivated_Crops_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 90)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Woody_Wetlands_sq_km,
    (SELECT pixel_count FROM landcover_raw_values WHERE pixel_value = 95)* SUM(ST_Area(rast::geometry::geography)) / (1000000.0 * total_pixels) AS total_area_Emergent_Herbaceous_Wetlands_sq_km
FROM classified_landcover_clipped_rast, pixel_summary
GROUP BY total_pixels;


-- Append to landcover_summary table
ALTER TABLE landcover_summary ADD COLUMN area_sq_km NUMERIC;

-- Update the area column using values from the landcover_area table
UPDATE landcover_summary AS ls
SET area_sq_km = 
    CASE 
        WHEN ls.landcover_type = 'Open Water' THEN la.total_area_Open_Water_sq_km
        WHEN ls.landcover_type = 'Developed, Open Space' THEN la.total_area_Developed_Open_Space_sq_km
        WHEN ls.landcover_type = 'Developed, Low Intensity' THEN la.total_area_Developed_Low_sq_km
        WHEN ls.landcover_type = 'Developed, Medium Intensity' THEN la.total_area_Developed_Medium_sq_km
        WHEN ls.landcover_type = 'Developed High Intensity' THEN la.total_area_Developed_High_sq_km
        WHEN ls.landcover_type = 'Barren Land (Rock/Sand/Clay)' THEN la.total_area_Barren_Land_sq_km
        WHEN ls.landcover_type = 'Deciduous Forest' THEN la.total_area_Deciduous_Forest_sq_km
        WHEN ls.landcover_type = 'Evergreen Forest' THEN la.total_area_Evergreen_Forest_sq_km
        WHEN ls.landcover_type = 'Mixed Forest' THEN la.total_area_Mixed_Forest_sq_km
        WHEN ls.landcover_type = 'Shrub/Scrub' THEN la.total_area_Shrub_Scrub_sq_km
        WHEN ls.landcover_type = 'Grassland/Herbaceous' THEN la.total_area_Grassland_Herbaceous_sq_km
        WHEN ls.landcover_type = 'Pasture/Hay' THEN la.total_area_Pasture_Hay_sq_km
        WHEN ls.landcover_type = 'Cultivated Crops' THEN la.total_area_Cultivated_Crops_sq_km
        WHEN ls.landcover_type = 'Woody Wetlands' THEN la.total_area_Woody_Wetlands_sq_km
        WHEN ls.landcover_type = 'Emergent Herbaceous Wetlands' THEN la.total_area_Emergent_Herbaceous_Wetlands_sq_km
        ELSE NULL
    END
FROM landcover_area AS la;