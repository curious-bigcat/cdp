# Snowflake CDP Demo with Hightouch, Braze, and Marketplace Data

This guide outlines a reproducible demo that showcases how a Snowflake-centric customer data platform can activate enriched customer profiles in Braze using Hightouch and Snowflake Marketplace data products.

## 1. Storyboard

1. **Business prompt** – Marketing wants to re-engage lapsed premium shoppers with a personalized offer. They need fresh lifestyle attributes to segment accurately.
2. **Data strategy** – Blend first-party behavioral data with third-party demographic and lifestyle signals from the Snowflake Marketplace.
3. **Activation** – Build the segment in Snowflake, sync to Braze via Hightouch, and launch a targeted campaign.
4. **Measurement** – Capture engagement metrics back in Snowflake for closed-loop reporting.

## 2. Reference Architecture

- **Snowflake** – Central warehouse, houses raw events, curated profiles, and Marketplace shares.
- **Snowflake Marketplace Data Product** – e.g., LiveRamp Consumer Attributes (or any enrichment provider the audience recognizes). Consumed via reader account or listing subscription.
- **Hightouch** – Reverse ETL platform reading Snowflake tables/views and writing to Braze Users or Custom Attributes endpoints.
- **Braze** – Engagement platform receiving enriched traits for segmentation and campaign personalization.

```text
Marketplace Listing --> Snowflake (Raw + Curated) --> Hightouch Sync --> Braze
                                 ^                                      |
                                 |---------------- Metrics -------------|
```

## 3. Prerequisites

- Snowflake account with access to the desired Marketplace listing.
- Database objects: `RAW`, `ENRICHED`, `ACTIVATION` schemas (or your naming convention).
- Service account / key pair for Hightouch with `USAGE`, `SELECT` on activation views.
- Braze workspace API key with permission to update users.
- Optional: dbt project or Snowflake-native tasks for model orchestration.

## 4. Data Preparation Steps

### Base demo dataset (first-party)

Start with the canonical CDP entities your stakeholders expect to see: customers, orders, behavioral events, and subscriptions. The snippet below creates synthetic-but-realistic data that you can keep refreshing before each run.

```sql
use role sysadmin;
create or replace database DEMO_CDP;
create or replace schema DEMO_CDP.RAW;
create or replace schema DEMO_CDP.ENRICHED;
create or replace schema DEMO_CDP.ACTIVATION;

-- Customers with marketing-friendly attributes
create or replace table DEMO_CDP.RAW.CUSTOMERS as
select
    seq4()::number as customer_id,
    concat('user', lpad(seq4()::varchar, 6, '0'), '@acme-retail.com') as email,
    uniform(0,1,random(1)) as email_opt_in,
    array_construct('WEB','STORE','APP')[uniform(0,3,random(2))] as acquisition_channel,
    object_construct('tier', iff(uniform(0,100,random(3)) > 80,'Gold','Standard')) as loyalty_profile,
    dateadd(day, -uniform(0,720,random(4)), current_date()) as signup_date,
    'US' as country
from table(generator(rowcount => 50000));

-- Orders / subscriptions
create or replace table DEMO_CDP.RAW.ORDERS as
select
    uniform(1,50000,random(5)) as customer_id,
    uniform(1,10,random(6)) as product_id,
    dateadd(day, -uniform(0,365,random(7)), current_date()) as order_date,
    round(uniform(25,250,random(8)),2) as order_value,
    iff(uniform(0,100,random(9))>70,'subscription','one_time') as order_type,
    sha2(concat(customer_id, order_date), 256) as order_id
from table(generator(rowcount => 120000));

-- Web / app events
create or replace table DEMO_CDP.RAW.EVENTS as
select
    uniform(1,50000,random(10)) as customer_id,
    dateadd(minute, -uniform(0,60000,random(11)), current_timestamp()) as event_ts,
    array_construct('product_view','add_to_cart','checkout_start','email_click')[uniform(0,4,random(12))] as event_name,
    object_construct('sku', concat('SKU-', uniform(100,999,random(13)))) as event_payload
from table(generator(rowcount => 500000));

grant usage on database DEMO_CDP to role svc_hightouch;
grant select on all tables in schema DEMO_CDP.RAW to role svc_hightouch;
```

With those seeded, materialize your unified profile (or hand it off to dbt) so downstream tools only query curated entities:

```sql
create or replace view DEMO_CDP.ENRICHED.DIM_CUSTOMER as
select
    c.customer_id,
    c.email,
    c.email_opt_in,
    c.acquisition_channel,
    c.loyalty_profile:tier::string as loyalty_tier,
    c.signup_date,
    nvl(sum(o.order_value) over (partition by c.customer_id),0) as lifetime_value,
    max(o.order_date) over (partition by c.customer_id) as last_order_date
from DEMO_CDP.RAW.CUSTOMERS c
left join DEMO_CDP.RAW.ORDERS o using(customer_id);
```

### Marketplace enrichment touchpoint

Pull a lifestyle/propensity dataset from Snowflake Marketplace and attach it to those base profiles. Replace the listing names with the actual share you subscribe to—if you are already using LiveRamp’s native app you can double-dip and pull their enrichment feeds as well.

```sql
-- Once approved for the listing, create the zero-copy database
create or replace database MARKETPLACE_ENRICHMENT
from share "PROVIDER_ACCOUNT"."LISTING_SHARE";

-- Optional: narrow to the columns you plan to demo
create or replace view MARKETPLACE_ENRICHMENT.CONSUMER_ATTRIBUTES as
select
    email_hash,
    household_income_bucket,
    lifestyle_cluster,
    propensity_travel,
    propensity_luxury_retail
from MARKETPLACE_ENRICHMENT.PUBLIC.CONSUMER_MASTER;
```

Hash alignment between your first-party emails and the Marketplace dataset keeps the demo privacy-safe:

```sql
create or replace view DEMO_CDP.ENRICHED.V_MPX_ENRICHED as
select
    d.*,
    m.household_income_bucket,
    m.lifestyle_cluster,
    m.propensity_travel,
    m.propensity_luxury_retail
from DEMO_CDP.ENRICHED.DIM_CUSTOMER d
left join MARKETPLACE_ENRICHMENT.CONSUMER_ATTRIBUTES m
    on m.email_hash = sha2(lower(d.email), 256);
```

### Identity key + partner translation (LiveRamp reference)

Anchor your activation schema on a durable identity that every downstream partner (Braze, Meta, Google, Retail Media) can accept. Follow the **LiveRamp Identity and Translation Quickstart**:

1. **Install the native app** – Request access to the LiveRamp Identity Resolution & Transcoding application in your Snowflake region.
2. **Create input + metadata tables** – Store raw PII in `DEMO_CDP.RAW.CUSTOMERS_PII` and describe each column in the metadata table using their template:

```sql
create or replace table DEMO_CDP.RAW.CUSTOMER_IDENTITY_META as
select
    '<client_id>' as client_id,
    '<client_secret>' as client_secret,
    'resolution' as execution_mode,
    'pii' as execution_type,
    parse_json('{
      "name": ["first_name","last_name"],
      "streetAddress": ["street_1","street_2"],
      "city": "city",
      "state": "state",
      "zipCode": "postal_code",
      "phone": "phone_number",
      "email": "email"
    }') as target_columns,
    1 as limit;
```

3. **Run the stored procedures** – Call `lr_resolution_and_transcoding(<input_table>, <meta_table>, <output_table>)` followed by `check_for_output($output_table)` to materialize the resolved IDs.
4. **Audit + join** – Use the output table’s `__LR_FILTER_NAME` and `__LR_RANK` columns to show match quality, then join the durable `LR_ID` back into `DEMO_CDP.ENRICHED.V_MPX_ENRICHED`. This is the same ID you will pass along through Hightouch to Braze, Meta CAPI, and Google Ads audiences.

1. **Ingest first-party data**
   - Load clickstream, orders, subscription status into `RAW.EVENTS`, `RAW.ORDERS`, etc.
   - Use Snowpipe or Streamlit demo to illustrate near-real-time ingestion.
   - If you need a turnkey Braze-facing schema, follow the Braze Cloud Data Ingestion quickstart to provision the `BRAZE_CLOUD_PRODUCTION.INGESTION` objects (`users_attributes_sync_vw`, `users_deletes_vw`) and the `svc_braze_cdi` service user/role/warehouse. This gives you a governed landing zone for attributes that CDI can poll without additional transformation work.

2. **Subscribe to Marketplace data**
   - In the Snowflake UI, find the enrichment listing, request the share, and create a database (e.g., `MARKETPLACE_ENRICHMENT`).
   - Document key attributes available (household income, propensity scores, interest tags).

3. **Model unified customers**
   - Create a customer dimension in `ENRICHED.DIM_CUSTOMER` with joining logic.
   - Blend Marketplace columns via hashed email or other join keys.

```sql
create or replace view ENRICHED.V_CUSTOMER_PROFILE as
select
    c.customer_id,
    c.email,
    max(o.last_order_date) as last_purchase_at,
    sum(o.order_value) as lifetime_value,
    m.lifestyle_cluster,
    m.hhi_bucket,
    current_timestamp() as profile_ts
from ENRICHED.DIM_CUSTOMER c
left join ENRICHED.FCT_ORDERS o on o.customer_id = c.customer_id
left join MARKETPLACE_ENRICHMENT.CONSUMER_ATTRIBUTES m
       on m.email_hash = sha2(c.email, 256)
group by 1,2,5,6;
```

4. **Define activation-ready segment**

```sql
create or replace view ACTIVATION.V_LAPSED_PREMIUM as
select *
from ENRICHED.V_CUSTOMER_PROFILE
where last_purchase_at < dateadd(month, -3, current_date())
  and lifetime_value > 500
  and lifestyle_cluster = 'Premium Adventurers';
```

5. **Resolve durable identity + translation**
   - Use the LiveRamp native app output from the earlier subsection to stitch multiple identifiers (email, phone, postal) into a single `LR_ID`.
   - Persist the resolved IDs in `ENRICHED.DIM_CUSTOMER` (or downstream view) so Braze, Meta, and Google all receive the same `external_id`.
   - If you need partner-specific RampIDs (e.g., `LR_PARTNER_META`, `LR_PARTNER_GOOGLE`), rerun the app in **translation** mode so you can demo end-to-end partner onboarding without exporting PII.

## 5. Hightouch Configuration

1. **Source setup**
   - Connect Snowflake using the service user.
   - Sync frequency: manual for demo, cron for production.

2. **Model import**
   - Point to `ACTIVATION.V_LAPSED_PREMIUM`.
   - Primary key: `customer_id`. Enable change tracking if available.

3. **Destination mapping (Braze)**
   - Destination: Braze Users.
   - External ID: `customer_id` or hashed email.
   - Map attributes: `lifestyle_cluster`, `lifetime_value`, `last_purchase_at`.
   - Optional: create Braze custom events for LTV buckets.

4. **Sync run**
   - Trigger a manual sync, show row counts, highlight upserts vs. updates.
   - Capture logs to explain data governance (PII hashed in Snowflake, only needed fields sent).

### Optional: pair Hightouch with Braze CDI automation

If stakeholders want to see Braze’s native pipeline alongside Hightouch, reuse the **Braze Cloud Data Ingestion** quickstart:

1. **Provision dedicated objects**

```sql
use role accountadmin;
create or replace role braze_cdi_role;
create or replace user svc_braze_cdi type = service default_role = braze_cdi_role;
create or replace warehouse braze_cdi_wh warehouse_size = 'XSMALL';
grant usage on warehouse braze_cdi_wh to role braze_cdi_role;
create or replace database braze_cloud_production;
grant ownership on database braze_cloud_production to role braze_cdi_role;
```

2. **Stage the payload tables and views**

```sql
use role braze_cdi_role;
create or replace schema braze_cloud_production.ingestion;
create or replace table braze_cloud_production.ingestion.users_attributes_sync (
    external_id varchar,
    payload varchar,
    updated_at timestamp_ntz default current_timestamp()
);
create or replace view braze_cloud_production.ingestion.users_attributes_sync_vw as
select * from braze_cloud_production.ingestion.users_attributes_sync where payload is not null;
create or replace view braze_cloud_production.ingestion.users_deletes_vw as
select external_id, updated_at from braze_cloud_production.ingestion.users_attributes_sync where payload is null;
```

3. **Automate with streams + tasks** – Create a stream on your activation table, copy deltas into `users_attributes_sync`, and schedule a Snowflake task to run every few minutes so Braze CDI polls fresh payloads while Hightouch continues to drive high-frequency reverse ETL jobs.

## 6. Braze Demo Flow

1. **Segment verification**
   - In Braze, filter on `lifestyle_cluster = Premium Adventurers` and `last_purchase_at > 90 days`.
   - Confirm the enriched attributes now exist.
   - Optionally show the CDI connection pulling from `users_attributes_sync_vw` to prove governed delivery alongside the Hightouch sync. Highlight how CDI handles deletions via `users_deletes_vw` if the audience asks about suppression or privacy workflows.

2. **Campaign setup**
   - Create Canvas or Email campaign using personalization tokens:
     - Subject: `{{custom_attribute.lifestyle_cluster}} Exclusive Offer`
     - Body references `lifetime_value` bucket for tailored incentive.

3. **Send test messages**
   - Use test user seeded from activation view.
   - Highlight dynamic content capabilities.

## 7. Paid Media Extensions with Hightouch

### Facebook Conversions API signal boost

Leverage the **Improving Ad Performance with Facebook CAPI** quickstart to extend the same Snowflake audience into paid social:

- **Connectors** – Use Snowflake Partner Connect to spin up the `PC_HIGHTOUCH` database/user/role, then add the Facebook Conversions destination in Hightouch with OAuth and Pixel ID.
- **Model** – Point the model SQL at the activation table (or join events + customer tables) so each row is a unique conversion event with timestamps in the last seven days:

```sql
select
    e.event_id,
    e.event_ts,
    c.lr_id as external_id,
    c.email,
    c.phone,
    c.ltv_bucket,
    e.order_value
from DEMO_CDP.ACTIVATION.EVENT_CONVERSIONS e
join DEMO_CDP.ENRICHED.DIM_CUSTOMER c on c.customer_id = e.customer_id;
```

- **Sync** – Map the relevant fields to Facebook’s `user_data`, enable hashing in Hightouch, and schedule the sync every 15 minutes so Meta optimizes on server-side conversions.

### YouTube suppression audience (Google Ads)

The **Suppress Existing Customers from YouTube Campaigns** quickstart gives you a no-code flow to exclude recent purchasers:

- **Test data** – Reuse the `customer_sales` view from the guide or point the parent model at `DEMO_CDP.ENRICHED.DIM_CUSTOMER`.
- **Parent model + audiences** – In Hightouch Audiences, configure the parent model with `customer_id` as the key, add a condition like “`last_order_date is within 60 days`” to capture recently converted users, and save it as `YT_Suppression`.
- **Destination** – Add a Google Ads Customer Match destination (OAuth login), select the `Customer List` subtype for YouTube, and choose hashed email/phone identifiers produced via LiveRamp.
- **Automation** – Run the audience sync once live, then schedule it hourly so any new purchasers automatically flow into Google Ads suppression lists, protecting budget.

## 8. Marketplace Storytelling Tips

- Emphasize zero-copy data sharing and governance controls.
- Call out speed to value: no new pipelines needed, share becomes instantly queryable.
- Mention option to rotate among different data providers depending on vertical.

## 9. Measurement & Loop Closure

- Create a Braze webhook or S3 export into Snowflake stage.
- Use Snowpipe to land engagement events (`EMAIL_OPEN`, `CLICK`).
- Join back to `ENRICHED.V_CUSTOMER_PROFILE` to calculate uplift.
- Stretch goal: reuse the Cortex-based "Marketing Insight Navigator" pattern to let marketers ask natural-language questions of those engagement tables directly inside Snowsight. The Braze Email Engagement + Cortex quickstart walks through building semantic models, metrics, and a Streamlit app that surfaces AI-written summaries and follow-up analyses.

### Cortex environment prep

```sql
alter account set cortex_enabled_cross_region = 'ANY_REGION';
create or replace database BRAZE_ENGAGEMENT;
create or replace schema BRAZE_ENGAGEMENT.EMAIL_DATA;
create or replace stage BRAZE_ENGAGEMENT.EMAIL_DATA.EMAIL_STAGE directory = (enable = true);
```

Load Braze data-share tables (sends, opens, clicks, unsubscribes) into that schema, mirroring the quickstart DDL so Cortex has a consistent semantic layer.

### Semantic model + Streamlit app

1. Define a Cortex Analyst semantic model referencing the email fact tables plus a `CAMPAIGN_CHANGELOGS` dimension for metadata.
2. Train metrics such as `open_rate`, `click_through_rate`, `conversion_rate`, and expose them to Cortex Complete.
3. Deploy the provided Streamlit “Marketing Insight Navigator” app so marketers can ask questions like “Which June campaigns underperformed among Premium Adventurers?” and get AI-written summaries backed by Snowflake data.

```sql
create or replace view ENRICHED.V_CAMPAIGN_PERF as
select
    l.customer_id,
    l.lifestyle_cluster,
    e.event_type,
    e.event_timestamp
from ACTIVATION.V_LAPSED_PREMIUM l
join RAW.BRAZE_EVENTS e
  on e.external_id = l.customer_id;
```

## 10. Demo Script (10–12 minutes)

1. **Context (1 min)** – Business challenge and goal.
2. **Snowflake (3 min)** – Show Marketplace listing, share, curated views.
3. **Model walkthrough (2 min)** – Highlight SQL for segment, discuss governance.
4. **Hightouch (2 min)** – Live sync run, explain columns.
5. **Braze (2–3 min)** – Segment appears, preview personalized campaign.
6. **Wrap (1 min)** – Metrics flowing back, next steps (automate, expand providers).

## 11. Assets Checklist

- Slides: 3–4 supporting visuals (architecture, data flow, value prop).
- Snowflake worksheet with SQL snippets above.
- Hightouch sync screenshot or live credentials.
- Braze campaign in draft mode with personalization tokens.
- Optional dashboard (Looker/Mode) showing engagement uplift.
- Bonus artefacts if time allows:
  - Screenshot of the Braze CDI connection test screen (validates zero-copy integration).
  - Cortex Streamlit app snippet answering “Which campaigns saw highest engagement in June 2025?”.

Use this plan as a script plus technical blueprint. Swap specific data providers or audience segments based on who you are demoing to, but keep the zero-copy enrichment + activation narrative consistent.

## 12. Reference Playbooks to Borrow From

- **Braze Cloud Data Ingestion (CDI) Quickstart** – Shows how to create the dedicated Snowflake role/user/warehouse, `users_attributes_sync` table, and companion views that Braze polls. Reuse the stream-and-task pattern documented there if you want to automate attribute payload generation instead of relying solely on Hightouch.
- **AI-Powered Campaign Analytics with Braze + Snowflake Cortex** – Provides end-to-end instructions for standing up the Cortex semantic model, metrics, and Streamlit “Marketing Insight Navigator” app. Great for the measurement portion of the story or for a follow-on demo on AI-assisted campaign analytics.
- **Improving Ad Performance with Facebook CAPI via Hightouch** – Demonstrates how the same Snowflake audience tables can drive paid media conversion signals. Use it when you want to expand the narrative from Braze to performance ads or show multi-channel activation from a single activation schema.
- **Suppress Existing Customers from YouTube Campaigns with Hightouch** – Offers a no-code Hightouch Audiences flow for suppression lists. Reference it when discussing privacy-safe opt-out handling, or when audience asks how to operationalize exclusion segments alongside the Braze re-engagement campaign.
- **LiveRamp Identity & Translation Quickstart** – Details how to install the native application, configure metadata, execute resolution/transcoding, and audit match filters so you can showcase durable IDs and partner-specific RampIDs without exposing raw PII.

