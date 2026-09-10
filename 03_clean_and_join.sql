-- =============================================================================
-- 03_clean_and_join.sql
-- Buyer Segmentation & Investment Profiling — Parcl Real Estate
--
-- Step 1: Data Cleaning   -> dedupe, normalize labels, parse mixed date formats
-- Step 2/3 prep: creates one clean, client-level feature table ready for
--                encoding/scaling and clustering in Tableau
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1a. Remove exact duplicate client rows (same person, same attributes twice)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS clients_dedup;
CREATE TABLE clients_dedup AS
SELECT MIN(client_id) AS client_id, client_type, first_name, last_name,
       date_of_birth_raw, gender, country, region, acquisition_purpose,
       satisfaction_score, loan_applied, referral_channel
FROM clients_raw
GROUP BY client_type, first_name, last_name, date_of_birth_raw, gender,
         country, region, acquisition_purpose, satisfaction_score,
         loan_applied, referral_channel;

-- -----------------------------------------------------------------------------
-- 1b. Parse the two mixed date formats found in date_of_birth:
--     'DD-MM-YYYY' (dash-separated)  and  'MM/DD/YYYY' (slash-separated)
--     Normalize both into a proper ISO date (YYYY-MM-DD) SQLite can compute with
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS clients_clean;
CREATE TABLE clients_clean AS
SELECT
    client_id,
    CASE WHEN client_type IN ('Individual','Company') THEN client_type ELSE 'Unknown' END AS client_type,
    TRIM(first_name) AS first_name,
    TRIM(last_name)  AS last_name,
    CASE
        WHEN date_of_birth_raw LIKE '%-%' THEN
            -- dash format: DD-MM-YYYY
            substr(date_of_birth_raw, 7, 4) || '-' ||
            substr(date_of_birth_raw, 4, 2) || '-' ||
            substr(date_of_birth_raw, 1, 2)
        WHEN date_of_birth_raw LIKE '%/%' THEN
            -- slash format: M/D/YYYY or MM/DD/YYYY
            substr(date_of_birth_raw, -4, 4) || '-' ||
            printf('%02d', CAST(substr(date_of_birth_raw, 1, instr(date_of_birth_raw,'/')-1) AS INTEGER)) || '-' ||
            printf('%02d', CAST(substr(
                substr(date_of_birth_raw, instr(date_of_birth_raw,'/')+1),
                1, instr(substr(date_of_birth_raw, instr(date_of_birth_raw,'/')+1),'/')-1
            ) AS INTEGER))
        ELSE NULL
    END AS date_of_birth_iso,
    UPPER(TRIM(gender)) AS gender,
    TRIM(country) AS country,
    TRIM(region) AS region,
    TRIM(acquisition_purpose) AS acquisition_purpose,
    satisfaction_score,
    CASE WHEN UPPER(TRIM(loan_applied)) = 'YES' THEN 1 ELSE 0 END AS loan_applied_flag,
    TRIM(referral_channel) AS referral_channel
FROM clients_dedup;

-- -----------------------------------------------------------------------------
-- 1c. Clean properties: parse transaction_date, strip $ and commas from price
--     (done before age calc, since age uses the latest transaction date)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS properties_clean;
CREATE TABLE properties_clean AS
SELECT
    listing_id,
    tower_number,
    -- transaction_date is consistently DD-MM-YYYY in this file
    substr(transaction_date_raw, 7, 4) || '-' ||
    substr(transaction_date_raw, 4, 2) || '-' ||
    substr(transaction_date_raw, 1, 2) AS transaction_date_iso,
    unit_category,
    unit_number,
    floor_area_sqft,
    CAST(REPLACE(REPLACE(sale_price_raw, '$', ''), ',', '') AS REAL) AS sale_price,
    listing_status,
    client_ref
FROM properties_raw;

-- -----------------------------------------------------------------------------
-- 1d. Derive age from the normalized date of birth (reference date: dataset's
--     most recent transaction date, since that's the most meaningful "as of")
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS clients_with_age;
CREATE TABLE clients_with_age AS
SELECT
    cc.*,
    CAST((julianday((SELECT MAX(transaction_date_iso) FROM properties_clean))
          - julianday(cc.date_of_birth_iso)) / 365.25 AS INTEGER) AS age
FROM clients_clean cc;

-- -----------------------------------------------------------------------------
-- 2b. Client-level purchase aggregates (only SOLD units count as purchases)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS client_purchase_agg;
CREATE TABLE client_purchase_agg AS
SELECT
    client_ref AS client_id,
    COUNT(*) AS num_properties_purchased,
    SUM(sale_price) AS total_investment_value,
    AVG(sale_price) AS avg_purchase_price,
    AVG(floor_area_sqft) AS avg_floor_area_sqft,
    SUM(CASE WHEN unit_category = 'Office' THEN 1 ELSE 0 END) AS num_office_units,
    SUM(CASE WHEN unit_category = 'Apartment' THEN 1 ELSE 0 END) AS num_apartment_units,
    MIN(transaction_date_iso) AS first_purchase_date,
    MAX(transaction_date_iso) AS last_purchase_date
FROM properties_clean
WHERE listing_status = 'Sold' AND client_ref IS NOT NULL
GROUP BY client_ref;

-- -----------------------------------------------------------------------------
-- 3. FINAL client_features table: one row per client, ready for
--    encoding/scaling in Excel and clustering in Tableau
--    (buyers with zero purchases get 0s via LEFT JOIN + COALESCE)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS client_features;
CREATE TABLE client_features AS
SELECT
    ca.client_id,
    ca.client_type,
    ca.first_name || ' ' || ca.last_name AS full_name,
    ca.age,
    ca.gender,
    ca.country,
    ca.region,
    ca.acquisition_purpose,
    ca.satisfaction_score,
    ca.loan_applied_flag,
    ca.referral_channel,
    COALESCE(pa.num_properties_purchased, 0) AS num_properties_purchased,
    COALESCE(pa.total_investment_value, 0)   AS total_investment_value,
    COALESCE(pa.avg_purchase_price, 0)       AS avg_purchase_price,
    COALESCE(pa.avg_floor_area_sqft, 0)      AS avg_floor_area_sqft,
    COALESCE(pa.num_office_units, 0)         AS num_office_units,
    COALESCE(pa.num_apartment_units, 0)      AS num_apartment_units,
    pa.first_purchase_date,
    pa.last_purchase_date,
    CASE WHEN pa.num_properties_purchased >= 2 THEN 1 ELSE 0 END AS is_repeat_buyer
FROM clients_with_age ca
LEFT JOIN client_purchase_agg pa ON pa.client_id = ca.client_id;
