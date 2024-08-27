--create table in the schema
CREATE TABLE "Nexa_Sat".nexa_sat(
    Customer_Id VARCHAR(50),
    gender VARCHAR(10),
    Partner VARCHAR(3),
    Dependents VARCHAR(3),
    Senior_Citizen INT,
    Call_Duration FLOAT,
    Data_Usage FLOAT,
    Plan_Type VARCHAR(20),
    Plan_Level VARCHAR(20),
    Monthly_Bill_Amount FLOAT,
    Tenure_Months INT,
    Multiple_Lines VARCHAR(3),
    Tech_Support VARCHAR(3),
    Churn INT);

-- confirm current schema
SELECT current_schema();

-- set path for queries
SET search_path TO "Nexa_Sat";

-- view data
SELECT * 
FROM nexa_sat

-- DATA CLEANING
-- check for duplicates
SELECT Customer_Id, gender, Partner,
        Dependents, Senior_Citizen,
        Call_Duration, Data_Usage, 
        Plan_Type, Plan_Level, 
        Monthly_Bill_Amount, Tenure_Months,
        Multiple_Lines, Tech_Support, Churn
FROM nexa_sat
GROUP BY Customer_Id,   gender, Partner,
        Dependents, Senior_Citizen,
        Call_Duration, Data_Usage, 
        Plan_Type, Plan_Level, 
        Monthly_Bill_Amount, Tenure_Months,
        Multiple_Lines, Tech_Support, Churn
HAVING COUNT(*) > 1 -- filter out rows that are duplicates

-- check for null values
SELECT * 
FROM nexa_sat
WHERE customer_Id IS NULL
OR gender IS NULL
OR Partner IS NULL
OR Dependents IS NULL
OR Senior_Citizen IS NULL
OR Call_Duration IS NULL
OR Data_Usage IS NULL
OR Plan_Type IS NULL
OR Plan_Level IS NULL
OR Monthly_Bill_Amount IS NULL
OR Tenure_Months IS NULL
OR Multiple_Lines IS NULL
OR Tech_Support IS NULL
OR Churn IS NULL

-- EDA
-- total users
SELECT COUNT(Customer_id) AS current_users
FROM nexa_sat
WHERE churn = 0

-- total users by plan level
SELECT plan_level, COUNT(customer_id) AS total_users
FROM nexa_sat
GROUP BY 1

-- total users by plan level who are active
SELECT plan_level, COUNT(customer_id) AS total_users
FROM nexa_sat
WHERE churn = 0
GROUP BY 1

-- total revenue
SELECT ROUND(SUM(monthly_bill_amount::numeric), 2) AS revenue
FROM nexa_sat;

-- revenue by plan level
SELECT plan_level, ROUND(SUM(monthly_bill_amount::numeric), 2) AS revenue
FROM nexa_sat
GROUP BY 1
ORDER BY 1

----churn count by plan type and plan level
SELECT plan_level, plan_type, 
        COUNT(*) AS total_customers,
        SUM(churn) AS churn_count
FROM nexa_sat
GROUP BY 1,2
ORDER BY 1;

-- avg tenure by plan level
SELECT plan_level, ROUND(avg(tenure_months), 2) AS avg_tenure
FROM nexa_sat
GROUP BY 1;

--MARKETING SEGMENTS
-- create table of existing users
CREATE TABLE existing_users AS
SELECT * 
FROM nexa_sat
WHERE churn = 0;

--view new table
SELECT *
FROM existing_users;

-- calculate the average revenue per user ARPU for existing users
SELECT ROUND(AVG(monthly_bill_amount::int), 2) AS ARPU
FROM existing_users

-- calculate CLV (customer lifetime value)
ALTER TABLE existing_users
ADD COLUMN clv FLOAT;

UPDATE existing_users
SET clv = (monthly_bill_amount * tenure_months)

-- view new clv column
SELECT customer_id, clv
FROM existing_users;

-- clv score
-- monthly_bill = 40%, tenure = 30%, call_duration = 10%, data_usage = 10%, premium = 10%
ALTER TABLE existing_users
ADD COLUMN clv_score NUMERIC(10,2);

UPDATE existing_users
SET clv_score = 
            (0.4 * monthly_bill_amount) +
            (0.3 * tenure_months) +
            (0.1 * call_duration) +
            (0.1 * data_usage) +
            (0.1 * CASE WHEN plan_level = 'Premium'
                    THEN 1 ELSE 0
                    END);  

-- view new clv score column
SELECT customer_id, clv_score
FROM existing_users;

--group users into segments based on clv_score
ALTER TABLE existing_users
ADD COLUMN clv_segments VARCHAR;

UPDATE existing_users
SET clv_segments = 
            CASE WHEN clv_score > (SELECT percentile_cont(0.85)
                                    WITHIN GROUP (ORDER BY clv_score)
                                    FROM existing_users) THEN 'High Value'
                WHEN clv_score > (SELECT percentile_cont(0.50)
                                    WITHIN GROUP (ORDER BY clv_score)
                                    FROM existing_users) THEN 'Moderate Value'
                WHEN clv_score > (SELECT percentile_cont(0.25)
                                    WITHIN GROUP (ORDER BY clv_score)
                                    FROM existing_users) THEN 'Low Value'
                ELSE 'Churn Risk'
                END;

-- view segments
 SELECT customer_id, clv, clv_score, clv_segments
FROM existing_users;

--ANALYZING THE SEGMENTS
--avg bill and tenure per segment
SELECT clv_segments,
        ROUND(AVG(monthly_bill_amount::INT), 2) AS avg_monthly_charges,
        ROUND(AVG(tenure_months::INT), 2) AS avg_tenure
FROM existing_users
GROUP BY 1

--tech support and multiple lines percent
SELECT clv_segments,    
        ROUND(AVG(CASE WHEN tech_support = 'Yes' THEN 1 ELSE 0 END),2) AS tech_support_percent,  
        ROUND(AVG(CASE WHEN multiple_lines = 'Yes' THEN 1 ELSE 0 END),2) AS multiple_line_percent
FROM existing_users
GROUP BY 1;
-- revenue per segment

SELECT clv_segments, COUNT(customer_id),
    CAST(SUM(monthly_bill_amount * tenure_months) AS NUMERIC(10,2))AS total_revenue
FROM existing_users
GROUP BY 1;

--CROSS SELLING AND UP-SELLING
--cross Selling tech support to snr citizens
SELECT customer_id
FROM existing_users
WHERE senior_citizen = 1 -- senior citizens
AND dependents = 'No' --no children or tech savvy helpers
AND tech_support = 'No' --do not already have this service
AND (clv_segments = 'Churn Risk' OR clv_segments = 'Low Value'); 

--cross-selling multiple lines for partners and dependents
SELECT customer_id
FROM existing_users
WHERE multiple_lines = 'No'
AND (dependents = 'Yes' OR partner = 'Yes')
AND plan_level = 'Basic';

--up-selling: premium discount for basic users with churn risk
SELECT customer_id
FROM existing_users
WHERE clv_segments = 'Churn Risk'
AND plan_level = 'Basic';

--up-selling: Basic high value to premium for longer lock in period and in turn higher ARPU
SELECT plan_level, ROUND(AVG(monthly_bill_amount::INT),2) AS avg_bill, ROUND(AVG(tenure_months::INT),2) AS avg_tenure
FROM existing_users
WHERE clv_segments = 'High Value'
OR clv_segments = 'Moderate Value'
GROUP BY 1

--select customers
SELECT customer_id
FROM existing_users
WHERE plan_level = 'Basic'
AND (clv_segments = 'High Value' OR clv_segments = 'Moderate Value')
AND monthly_bill_amount >  150;

--CREATE STORED PROCEDURES
--snr citizens who will be offered tech support
CREATE FUNCTION tech_support_snr_citizens()
RETURNS TABLE (customer_id VARCHAR(50))
AS $$
BEGIN 
    RETURN QUERY
    SELECT eu.customer_id
    FROM existing_users as eu
    WHERE eu.senior_citizen = 1 -- senior citizens
    AND eu.dependents = 'No' --no children or tech savvy helpers
    AND eu.tech_support = 'No' --do not already have this service
    AND (eu.clv_segments = 'Churn Risk' OR eu.clv_segments = 'Low Value');
END;
$$ LANGUAGE plpgsql;

-- procedure for churn risk users
CREATE FUNCTION churn_risk_discount()
RETURNS TABLE(customer_id VARCHAR(50))
AS $$
BEGIN 
    RETURN QUERY
    SELECT eu.customer_id
    FROM existing_users as eu
    WHERE eu.clv_segments = 'Churn Risk'
    AND eu.plan_level = 'Basic';
END;
$$ LANGUAGE plpgsql

--high usage customers who will be offered an upgrade
CREATE FUNCTION high_usage_basic()
RETURNS TABLE (customer_id VARCHAR(50))
AS $$
BEGIN 
    RETURN QUERY
    SELECT eu.customer_id
    FROM existing_users eu
    WHERE eu.plan_level = 'Basic'
    AND (eu.clv_segments = 'High Value' OR eu.clv_segments = 'Moderate Value')
    AND eu.monthly_bill_amount >  150;
END;
$$ LANGUAGE plpgsql

-- USE PROCEDURES
--churn risk users
SELECT *
FROM churn_risk_discount()

--high usage basic
SELECT *
FROM high_usage_basic()
