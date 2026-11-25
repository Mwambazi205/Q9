-- ==========================================
-- ICT371 QUESTION 9: Farmer Cooperative Maize
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) UNIQUE NOT NULL,
  full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        VARCHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(12,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate    NUMERIC(10,2) NOT NULL,
  total_value  NUMERIC(14,2) NOT NULL,
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_value   NUMERIC(16,2) NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade required'; END IF;
  
  -- Rates: A = 5, B = 4, C = 3
  CASE p_grade
    WHEN 'A' THEN RETURN 5;
    WHEN 'B' THEN RETURN 4;
    WHEN 'C' THEN RETURN 3;
    ELSE RAISE EXCEPTION 'Unsupported grade %', p_grade;
  END CASE;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer'; END IF;
  
  IF p_weight IS NULL OR p_weight <= 0 THEN RAISE EXCEPTION 'Invalid weight'; END IF;
  
  -- Insert basic fields (trigger supplies unit_rate and total_value)
  INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid, unit_rate, total_value)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE, 0, 0); 
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_delivery_pricing() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Reject non-positive weight
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'weight_kg must be positive';
  END IF;
  
  -- Call function and set pricing
  NEW.unit_rate := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  
  RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_pricing 
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
-- Shows unpaid total. LEFT JOIN includes farmers with zero unpaid deliveries.
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f 
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id, delivered_on);
-- EXPLAIN SELECT * FROM deliveries WHERE farmer_id=1 AND delivered_on BETWEEN '2025-01-01' AND '2025-01-31';

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, 
        total_value = EXCLUDED.total_value;
END $$;

-- SELECT cron.schedule('maize-daily','30 1 * * *',$$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert farmers
INSERT INTO farmers(farmer_number, full_name) VALUES ('F001','Alice'),('F002','Bob'),('F003','Charlie');

-- 2. Load deliveries via procedure (Trigger calculates total_value)
CALL pr_receive_delivery(1,'A',100, CURRENT_DATE);
CALL pr_receive_delivery(1,'B',200, CURRENT_DATE);
CALL pr_receive_delivery(2,'C',150, CURRENT_DATE - 1);
CALL pr_receive_delivery(2,'A',300, CURRENT_DATE - 1);
CALL pr_receive_delivery(3,'B',250, CURRENT_DATE);
CALL pr_receive_delivery(3,'C', 50, CURRENT_DATE);

-- 3. Mark some as paid
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1,3);

-- 4. Check view (Charlie has unpaid, Bob has fully paid so far, Alice has one unpaid)
SELECT * FROM v_farmer_amount_due;

-- 5. Refresh summary
CALL pr_refresh_purchases(CURRENT_DATE);
SELECT * FROM daily_purchases;