-- Worksheet: Aurora Retail CDP - Snowflake Foundation + Acxiom Enrichment
-- Purpose: Provision core Snowflake objects, seed demo data, and run the Acxiom Data Enrichment native app.

/*
Section 1. Administrative prep (run as ACCOUNTADMIN)
*/
use role accountadmin;

create or replace role aurora_cdp_admin;
grant role aurora_cdp_admin to user <your_user>;

create or replace warehouse aurora_cdp_wh
  with warehouse_size = 'XSMALL'
  warehouse_type = 'STANDARD'
  auto_suspend = 120
  auto_resume = true
  initially_suspended = true;

grant usage on warehouse aurora_cdp_wh to role aurora_cdp_admin;

create or replace database aurora_cdp;
grant usage on database aurora_cdp to role aurora_cdp_admin;

grant ownership on schema aurora_cdp.public to role aurora_cdp_admin;

alter user <your_user> set default_role = aurora_cdp_admin, default_warehouse = aurora_cdp_wh, default_namespace = aurora_cdp.public;

/*
Section 2. Switch into the working role (run as aurora_cdp_admin)
*/
use role aurora_cdp_admin;
use warehouse aurora_cdp_wh;
use database aurora_cdp;

create or replace schema raw;
create or replace schema model;
create or replace schema app;

/*
Section 3. Landing tables for retail PII + transactional context
*/
use schema raw;

create or replace table customers_pi (
  recordId string,
  first string,
  middle string,
  last string,
  suffix string,
  line1 string,
  line2 string,
  city string,
  state string,
  zip string,
  email string,
  phone string,
  personId string,
  householdId string,
  addressId string,
  opt_in boolean,
  last_purchase_ts timestamp_ntz,
  lifetime_value number(12,2),
  loyalty_tier string
);

insert overwrite into customers_pi values
('AURORA-0001','Jamie',null,'Lee',null,'123 S Main St',null,'Denver','CO','80205','jamie.lee@example.com','5551237890',null,null,null,true,'2024-10-15',1580,'Gold'),
('AURORA-0002','Priya','K','Singh',null,'890 Ocean Ave','Apt 5','San Francisco','CA','94112','priya.singh@example.com','5554561122',null,null,null,true,'2024-11-03',980,'Silver');

/*
Section 4. Input view that matches Acxiom schema (all columns required, even if null)
*/
use schema model;

create or replace view customer_enrich_input as
select recordId, first, middle, last, suffix,
       line1, line2, city, state, zip,
       email, phone, personId, householdId, addressId
from aurora_cdp.raw.customers_pi;

/*
Section 5. Run Acxiom DATA_ENRICHMENT stored procedure
- Install the "Acxiom Data Enrichment" native app from Marketplace first, using database AURORA_APP
- Replace the schema/database below if your app name differs
*/
use database aurora_app; -- created by the Marketplace install
use schema app_public;   -- refer to README in the app for the exact schema name

call data_enrichment('AURORA_CDP.MODEL.CUSTOMER_ENRICH_INPUT');

/*
Section 6. Persist enriched results back into the CDP schema
*/
use database aurora_cdp;
use schema app;

create or replace table customer_enriched as
select src.*, enr.*
from aurora_cdp.raw.customers_pi src
join aurora_app.realid_results.customer_enrich_input_dataenrichment enr
  on src.recordId = enr.recordId;

/*
Section 7. Quality checks & KPIs
*/
select count(*) total_records,
       count(enr.recordId) matched_records,
       round(count(enr.recordId)/count(*)*100,2) match_pct
from aurora_cdp.raw.customers_pi src
left join aurora_app.realid_results.customer_enrich_input_dataenrichment enr
  on src.recordId = enr.recordId;

select loyalty_tier,
       avg(lifetime_value) avg_ltv,
       avg(ap005554) avg_cyber_monday_rank
from aurora_cdp.app.customer_enriched
where ap005554 is not null
group by 1
order by avg_ltv desc;

/*
Section 8. Task to refresh enrichment monthly (optional)
*/
use database aurora_app;
use schema app_public;

create or replace task data_enrichment_monthly
  warehouse = aurora_cdp_wh
  schedule = 'USING CRON 0 6 1 * * America/Chicago'
as
  call data_enrichment('AURORA_CDP.MODEL.CUSTOMER_ENRICH_INPUT');

alter task data_enrichment_monthly resume;
