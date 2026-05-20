
select * from games_payments limit 10;
select * from games_paid_users limit 10;

---------------------------------------------------
-- CTE başlatıyoruz 
WITH user_monthly_revenue AS (
    select
        user_id,   
        -- Her satırın hangi kullanıcıya ait olduğunu tutuyoruz
        DATE_TRUNC('month', payment_date) AS month,   
        -- Günlük tarihi, aylık seviyeye indiriyoruz
        -- yani: tüm aynı ay içindeki veriler tek bucket'a giriyor
        SUM(revenue_amount_usd) AS revenue  
        -- Aynı kullanıcı + aynı ay içindeki tüm ödemeleri topluyoruz
    FROM project.games_payments  
    -- Ham ödeme verisinin olduğu tablo
    GROUP BY 1,2  
    -- 1 = user_id, 2 = month grupla
),
user_revenue_lag AS (
    SELECT
        user_id,
        -- Kullanıcı ID
        month,
        -- Aylık tarih (DATE_TRUNC ile oluşturmuştuk)
        revenue,
        -- O kullanıcının o ay ödediği toplam para
        ---------------------------------------------------
        -- LAG = "bir önceki satırı getir"
        -- Burada: önceki AY bilgisini alıyoruz
        LAG(month) OVER (
            PARTITION BY user_id 
            -- Her kullanıcı için ayrı ayrı çalış, user'lar birbirine karışmaz
            ORDER BY month
            -- Ay bazında sırala, Jan → Feb → Mar şeklinde ilerler
        ) AS prev_month,
        -- Sonuç: kullanıcının bir önceki ödeme yaptığı ay
        ---------------------------------------------------
        -- LAG = önceki satırın revenue'su
        LAG(revenue) OVER (
            PARTITION BY user_id 
            -- Yine user bazında
            ORDER BY month
            -- Zaman sırası
        ) AS prev_revenue,
        -- Sonuç: önceki ay ne kadar ödeme yapmış
        ---------------------------------------------------
        -- LEAD = "bir sonraki satırı getir"
        LEAD(month) OVER (
            PARTITION BY user_id 
            -- Yine user bazlı
            ORDER BY month
            -- Zaman sırasına göre
        ) AS next_month
        -- Sonuç: kullanıcı bir sonraki ay ödeme yapmış mı?
    FROM user_monthly_revenue
    -- Bu tablo: user + month + revenue içeriyordu
),
metrics AS (
    SELECT
        user_id,
        month,
        revenue,
        prev_revenue,
        next_month,
        ---------------------------------------------------
        -- 1. NEW PAID USER
        -- Kullanıcı ilk kez ödeme yapıyorsa
        CASE 
            WHEN prev_revenue IS NULL THEN 1 
            ELSE 0 
        END AS is_new_paid_user,
        ---------------------------------------------------
        -- 2. CHURNED USER
        -- Sonraki ay yoksa kullanıcı kaybolmuş
        CASE 
            WHEN next_month IS NULL THEN 1 
            ELSE 0 
        END AS is_churned_user,
        ---------------------------------------------------
        -- 3. EXPANSION MRR
        -- Önceki aya göre artış varsa
        CASE 
            WHEN revenue > prev_revenue 
            THEN revenue - prev_revenue
            ELSE 0 
        END AS expansion_mrr,
        ---------------------------------------------------
        -- 4. CONTRACTION MRR
        -- Önceki aya göre düşüş varsa
        CASE 
            WHEN revenue < prev_revenue 
            THEN prev_revenue - revenue
            ELSE 0 
        END AS contraction_mrr,
        ---------------------------------------------------
        -- 5. BACK FROM CHURN MRR
        -- Arada boşluk varsa (kullanıcı kaybolup geri gelmiş)
        CASE 
            WHEN prev_revenue IS NULL 
                 AND next_month IS NOT NULL
            THEN revenue
            ELSE 0 
        END AS back_from_churn_mrr
    FROM user_revenue_lag
)
-- CTE'yi çağırıyoruz
SELECT
    DATE_TRUNC('month', month) AS month,
    -- month zaten DATE_TRUNC ile aylık hale getirilmişti, tekrar güvenli şekilde ay bazında sabitliyoruz
    
    -- DIMENSIONS (FILTER İÇİN)
    u.language,
    u.age,
    u.game_name,
    
    SUM(revenue) AS mrr,                                                         -- tüm kullanıcıların aylık revenue toplamı
    COUNT(DISTINCT m.user_id) AS paid_users,                                     -- belirli dönemde ödeme yapan benzersiz kullanıcı sayısı
    SUM(is_new_paid_user) AS new_paid_users,                                     -- yani bu ay ilk kez ödeme yapan kullanıcı sayısı
    SUM(CASE WHEN m.is_new_paid_user = 1 THEN m.revenue ELSE 0 END) AS new_mrr,  -- o ay sisteme yeni giren kullanıcıların oluşturduğu toplam gelir
    SUM(is_churned_user) AS churned_users,                                       -- yani bu ay son kez görünen / kaybedilen kullanıcılar
    SUM(expansion_mrr) AS expansion_mrr,                                         -- mevcut kullanıcıların revenue artışı
    SUM(contraction_mrr) AS contraction_mrr,                                     -- mevcut kullanıcıların harcama düşüşü
    SUM(back_from_churn_mrr) AS back_from_churn_mrr                              -- daha önce kaybolmuş kullanıcıların geri dönüş geliri

FROM metrics m
LEFT JOIN games_paid_users u ON m.user_id = u.user_id
GROUP BY 1,2,3,4
ORDER BY 1;
