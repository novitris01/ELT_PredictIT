CREATE DATABASE raw

CREATE storage integration s3_int type = external_stage storage_provider = 'S3' storage_aws_role_arn = 'arn:aws:iam::001234567890:role/myrole' enabled = true storage_allowed_locations = ('s3://bucket/folder/');

--Create a stage
CREATE
	OR REPLACE STAGE raw_predictit storage_integration = s3_int file_format = (type = json) url = 's3://bucket/folder/'

--Select from stage
SELECT metadata$filename
	,*
FROM @raw_predictit

CREATE
	OR replace TABLE tbl_raw_predictit (
	file_name VARCHAR(100)
	,raw_value variant
	);

--demo copy
copy
INTO tbl_raw_predictit(file_name, raw_value)
FROM (
	SELECT metadata$filename
		,t.$1
	FROM @raw_predictit T
	);

--- create first task
CREATE TASK task_insert_raw_predictit WAREHOUSE = COMPUTE_WH SCHEDULE = 'USING CRON 0 2 * * * America/Los_Angeles' TIMESTAMP_INPUT_FORMAT = 'YYYY-MM-DD HH24' AS copy
INTO raw_predictit(file_name, raw_value)
FROM (
	SELECT metadata$filename
		,t.$1
	FROM @raw_predictit T
	);

--check if task's status is started 
SHOW TASKS;

-- start task
ALTER TASK PUBLIC.task_insert_raw_predictit RESUME;

--
-- create table for market data
CREATE
	OR replace TABLE stg_predictit_markets (
	id INT
	,predictit_name VARCHAR(200)
	,predictit_short_name VARCHAR(100)
	,predicit_url VARCHAR(500)
	);

-- Create task to insert into market data   
CREATE
	OR REPLACE TASK task_insert_stg_predictit_market WAREHOUSE = COMPUTE_WH TIMESTAMP_INPUT_FORMAT = 'YYYY-MM-DD HH24' AFTER task_insert_raw_predictit AS

INSERT INTO stg_predictit_markets
WITH raw_predictit AS (
		SELECT DISTINCT cast(parse_json(markets_json.value) :id AS INT) AS id
			,replace(parse_json(markets_json.value) :name, '"', '') AS predictit_name
			,replace(parse_json(markets_json.value) :shortName, '"', '') AS predictit_short_name
			,replace(parse_json(markets_json.value) :url, '"', '') AS predictit_url
		FROM raw.PUBLIC.tbl_raw_predictit
			,lateral flatten(parse_json(raw_value) :markets) markets_json
		)
SELECT raw_predictit.*
FROM raw_predictit
LEFT JOIN stg_predictit_markets stg_predictit ON raw_predictit.id = stg_predictit.id
WHERE stg_predictit.id IS NULL
ORDER BY 1;

-- Stop and then restart tasks             
ALTER TASK PUBLIC.task_insert_raw_predictit SUSPEND;

ALTER TASK PUBLIC.task_insert_stg_predictit_market RESUME;

ALTER TASK PUBLIC.task_insert_raw_predictit RESUME;

-- contract query  
SELECT parse_json(market_values.value) :id AS predictit_id
	,parse_json(contracts.value) :id AS predictit_contract_id
	,parse_json(contracts.value) :image AS IMAGE
	,parse_json(contracts.value) :dateEnd AS end_date
	,parse_json(contracts.value) :name AS contract_name
	,parse_json(contracts.value) :status AS contract_status_name
	,parse_json(contracts.value) :shortName AS contract_short_name
	,parse_json(contracts.value) :lastTradePrice AS last_trade_price
	,parse_json(contracts.value) :bestBuyYesCost AS best_buy_yes_cost
	,parse_json(contracts.value) :bestBuyNoCost AS best_buy_no_cost
	,parse_json(contracts.value) :bestSellYesCost AS best_sell_yes_cost
	,parse_json(contracts.value) :bestSellNoCost AS best_sell_no_cost
	,parse_json(contracts.value) :lastClosePrice AS last_close_price
	,cast(replace(split(split(file_name, '_') [1], '.') [0], '"', '') AS INT) AS dateid
FROM tbl_raw_predictit
	,lateral flatten(parse_json(raw_value) :markets) market_values
	,lateral flatten(parse_json(market_values.value) :contracts) contracts
ORDER BY 2
	,1
