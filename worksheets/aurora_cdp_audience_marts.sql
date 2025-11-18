-- Worksheet: Aurora Retail CDP - Audience-ready marts for Hightouch Customer Studio
-- Purpose: Create curated tables and incremental change views sourced from enriched attributes.

use role aurora_cdp_admin;
use warehouse aurora_cdp_wh;
use database aurora_cdp;
use schema app;

/*
Section 1. Curated customer dimension with enrichment highlights
*/
create or replace table dim_customer_enriched as
select recordId,
       first, last, city, state, zip,
       loyalty_tier,
       lifetime_value,
       opt_in,
       last_purchase_ts,
       ap005554 as cyber_monday_rank,
       ap006772 as ondemand_food_rank,
       ap004781 as costco_member_rank,
       ap006470 as uber_propensity,
       ap006894 as lyft_propensity,
       current_timestamp() as snapshot_ts
from aurora_cdp.app.customer_enriched;

/*
Section 2. Audience traits (segment labels) for direct syncs
*/
create or replace view vw_customer_traits as
select recordId,
       case
         when cyber_monday_rank <= 5 and loyalty_tier = 'Gold' and opt_in then 'Luxury Cyber Monday'
         when costco_member_rank <= 4 then 'Warehouse Loyalist'
         when ondemand_food_rank <= 20 then 'Delivery Diehard'
         else 'General Retail'
       end as primary_segment,
       case when lifetime_value >= 1500 then 'High Value'
            when lifetime_value between 750 and 1499 then 'Medium Value'
            else 'Emerging'
       end as value_band,
       datediff('day', last_purchase_ts, current_timestamp()) as days_since_purchase,
       opt_in
from dim_customer_enriched;

/*
Section 3. Incremental change feed for Hightouch Live Sync
*/
create or replace view vw_customer_incremental as
select d.*, t.primary_segment, t.value_band, t.days_since_purchase
from dim_customer_enriched d
join vw_customer_traits t using (recordId)
where d.snapshot_ts >= dateadd('hour', -24, current_timestamp());

/*
Section 4. KPI aggregates for Snowflake dashboards
*/
create or replace view vw_enrichment_kpis as
select primary_segment,
       count(*) as household_cnt,
       round(avg(cyber_monday_rank),2) as avg_cyber_rank,
       round(avg(lifetime_value),2) as avg_ltv
from vw_customer_traits t
join dim_customer_enriched d using (recordId)
group by 1
order by household_cnt desc;

