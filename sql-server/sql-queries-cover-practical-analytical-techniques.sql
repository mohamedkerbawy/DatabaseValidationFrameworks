/*
T-SQL queries cover practical analytical techniques

Assumed tables:
  Customers(CustomerID, CustomerName, Country)
  Orders(OrderID, CustomerID, OrderDate, TotalAmount, Status)
  OrderItems(OrderID, ProductID, Quantity, UnitPrice)
  Products(ProductID, ProductName, CategoryID, Cost)
  Categories(CategoryID, CategoryName)
  Employees(EmployeeID, EmployeeName, ManagerID, DepartmentID, Salary)

Notes:
- These are standalone examples; run one query at a time.
- Query 14 uses @CategoryID; declare/set it before running.
- Queries using completed orders assume Status = 'Completed'.
*/

-- 1. Rank customers by total spending
WITH CustomerSpending AS (
    SELECT
        CustomerID,
        SUM(TotalAmount) AS TotalSpent
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
)
SELECT *,
    RANK() OVER (ORDER BY TotalSpent DESC) AS SpendingRank
FROM CustomerSpending;


-- 2. Find the top 3 products in each category
WITH ProductSales AS (
    SELECT
        p.ProductID,
        p.ProductName,
        c.CategoryName,
        SUM(oi.Quantity * oi.UnitPrice) AS Revenue
    FROM OrderItems AS oi
    JOIN Products AS p
        ON p.ProductID = oi.ProductID
    JOIN Categories AS c
        ON c.CategoryID = p.CategoryID
    GROUP BY p.ProductID, p.ProductName, c.CategoryName
),
Ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CategoryName
            ORDER BY Revenue DESC, ProductID
        ) AS rn
    FROM ProductSales
)
SELECT *
FROM Ranked
WHERE rn <= 3;


-- 3. Calculate a running total of monthly revenue
WITH MonthlySales AS (
    SELECT
        DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
)
SELECT *,
    SUM(Revenue) OVER (
        ORDER BY SalesMonth
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS RunningRevenue
FROM MonthlySales;


-- 4. Compare each month's revenue with the previous month
WITH MonthlySales AS (
    SELECT
        DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
),
Comparisons AS (
    SELECT *,
        LAG(Revenue) OVER (ORDER BY SalesMonth) AS PreviousRevenue
    FROM MonthlySales
)
SELECT *,
    Revenue - PreviousRevenue AS RevenueChange,
    100.0 * (Revenue - PreviousRevenue)
        / NULLIF(PreviousRevenue, 0) AS GrowthPercent
FROM Comparisons;


-- 5. Calculate a 3-month moving average
-- Note: this averages the current row and previous two available monthly rows.
-- Add a calendar table if missing calendar months must count as zero.
WITH MonthlySales AS (
    SELECT
        DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
)
SELECT *,
    AVG(Revenue) OVER (
        ORDER BY SalesMonth
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS MovingAverage
FROM MonthlySales;


-- 6. Identify customers who have never placed an order
SELECT
    c.CustomerID,
    c.CustomerName
FROM Customers AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM Orders AS o
    WHERE o.CustomerID = c.CustomerID
);


-- 7. Find customers who spent more than the average customer
-- The average is calculated across customers who have completed orders.
WITH CustomerSpending AS (
    SELECT
        CustomerID,
        SUM(TotalAmount) AS TotalSpent
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
)
SELECT *
FROM CustomerSpending
WHERE TotalSpent > (
    SELECT AVG(TotalSpent)
    FROM CustomerSpending
);


-- 8. Calculate each category's percentage of total revenue
WITH CategorySales AS (
    SELECT
        p.CategoryID,
        SUM(oi.Quantity * oi.UnitPrice) AS Revenue
    FROM OrderItems AS oi
    JOIN Products AS p
        ON p.ProductID = oi.ProductID
    GROUP BY p.CategoryID
)
SELECT
    CategoryID,
    Revenue,
    100.0 * Revenue / NULLIF(SUM(Revenue) OVER (), 0)
        AS RevenueSharePercent
FROM CategorySales;


-- 9. Calculate average order value (AOV)
-- Assumes one row per order in Orders.
SELECT
    COUNT(*) AS NumberOfOrders,
    SUM(TotalAmount) AS TotalRevenue,
    AVG(TotalAmount) AS AverageOrderValue
FROM Orders
WHERE Status = 'Completed';


-- 10. Compare sales performance year over year
WITH YearlySales AS (
    SELECT
        YEAR(OrderDate) AS SalesYear,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY YEAR(OrderDate)
),
YoY AS (
    SELECT *,
        LAG(Revenue) OVER (ORDER BY SalesYear) AS PreviousYearRevenue
    FROM YearlySales
)
SELECT *,
    100.0 * (Revenue - PreviousYearRevenue)
        / NULLIF(PreviousYearRevenue, 0) AS YoYGrowthPercent
FROM YoY;


-- 11. Find the latest order for every customer who has ordered
WITH RankedOrders AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CustomerID
            ORDER BY OrderDate DESC, OrderID DESC
        ) AS rn
    FROM Orders
)
SELECT *
FROM RankedOrders
WHERE rn = 1;


-- 12. Build an employee-management hierarchy
WITH EmployeeHierarchy AS (
    SELECT
        EmployeeID,
        EmployeeName,
        ManagerID,
        0 AS HierarchyLevel
    FROM Employees
    WHERE ManagerID IS NULL

    UNION ALL

    SELECT
        e.EmployeeID,
        e.EmployeeName,
        e.ManagerID,
        h.HierarchyLevel + 1
    FROM Employees AS e
    JOIN EmployeeHierarchy AS h
        ON e.ManagerID = h.EmployeeID
)
SELECT *
FROM EmployeeHierarchy
ORDER BY HierarchyLevel, EmployeeID
OPTION (MAXRECURSION 100);


-- 13. Find products that have never been included in an order item
SELECT
    p.ProductID,
    p.ProductName
FROM Products AS p
WHERE NOT EXISTS (
    SELECT 1
    FROM OrderItems AS oi
    WHERE oi.ProductID = p.ProductID
);


-- 14. Find customers who purchased every product in a category
-- Set @CategoryID to the category you want to analyze.
-- Example: DECLARE @CategoryID INT = 1;
SELECT
    c.CustomerID,
    c.CustomerName
FROM Customers AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM Products AS p
    WHERE p.CategoryID = @CategoryID
      AND NOT EXISTS (
          SELECT 1
          FROM Orders AS o
          JOIN OrderItems AS oi
              ON oi.OrderID = o.OrderID
          WHERE o.CustomerID = c.CustomerID
            AND o.Status = 'Completed'
            AND oi.ProductID = p.ProductID
      )
);


-- 15. Find customers who ordered on consecutive days
WITH OrderDays AS (
    SELECT DISTINCT
        CustomerID,
        CAST(OrderDate AS date) AS OrderDay
    FROM Orders
    WHERE Status = 'Completed'
),
PreviousDays AS (
    SELECT *,
        LAG(OrderDay) OVER (
            PARTITION BY CustomerID
            ORDER BY OrderDay
        ) AS PreviousOrderDay
    FROM OrderDays
)
SELECT *
FROM PreviousDays
WHERE DATEDIFF(DAY, PreviousOrderDay, OrderDay) = 1;


-- 16. Calculate the median completed order value
SELECT DISTINCT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY TotalAmount)
        OVER () AS MedianOrderValue
FROM Orders
WHERE Status = 'Completed';


-- 17. Detect potential duplicate customer records
-- Matching name and country identifies candidates, not confirmed duplicates.
SELECT
    CustomerName,
    Country,
    COUNT(*) AS DuplicateCount
FROM Customers
GROUP BY CustomerName, Country
HAVING COUNT(*) > 1;


-- 18. Identify unusually large completed orders using standard deviation
WITH OrderStats AS (
    SELECT
        AVG(TotalAmount) AS AvgAmount,
        STDEV(TotalAmount) AS StdDevAmount
    FROM Orders
    WHERE Status = 'Completed'
)
SELECT o.*
FROM Orders AS o
CROSS JOIN OrderStats AS s
WHERE o.Status = 'Completed'
  AND o.TotalAmount > s.AvgAmount + 3 * s.StdDevAmount;


-- 19. Segment customers using RFM analysis
-- Recency scores are reversed so more recent customers get higher scores.
WITH RFM AS (
    SELECT
        CustomerID,
        DATEDIFF(DAY, MAX(OrderDate), GETDATE()) AS RecencyDays,
        COUNT(*) AS Frequency,
        SUM(TotalAmount) AS Monetary
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
),
Scores AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY RecencyDays DESC) AS RecencyScore,
        NTILE(5) OVER (ORDER BY Frequency ASC) AS FrequencyScore,
        NTILE(5) OVER (ORDER BY Monetary ASC) AS MonetaryScore
    FROM RFM
)
SELECT *,
    CONCAT(RecencyScore, FrequencyScore, MonetaryScore) AS RFMScore
FROM Scores;


-- 20. Calculate the Pareto contribution of customers to total revenue
WITH CustomerRevenue AS (
    SELECT
        CustomerID,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
),
Ranked AS (
    SELECT *,
        SUM(Revenue) OVER (
            ORDER BY Revenue DESC, CustomerID
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS CumulativeRevenue,
        SUM(Revenue) OVER () AS TotalRevenue,
        ROW_NUMBER() OVER (
            ORDER BY Revenue DESC, CustomerID
        ) AS CustomerRank
    FROM CustomerRevenue
)
SELECT *,
    100.0 * CumulativeRevenue / NULLIF(TotalRevenue, 0)
        AS CumulativeRevenuePercent
FROM Ranked
ORDER BY CustomerRank;

-- 21. Subquery with IN Clause Example: Selecting employees in departments with specific IDs
SELECT *
FROM employees
WHERE department_id IN (SELECT department_id FROM departments WHERE department_name = 'Sales');

--22. Subquery with EXISTS Clause Example: Selecting employees with existing orders
SELECT *
FROM employees
WHERE EXISTS (SELECT 1 FROM orders WHERE orders.employee_id = employees.employee_id); 

-- 23. Self-Join for Hierarchy Example: Selecting employees and their managers
SELECT e.employee_name, m.employee_name AS manager_name
FROM employees e
JOIN employees m ON e.manager_id = m.employee_id;

-- 24. LEAD() and LAG() for Time-Based Analysis Example: Analyzing the change in sales over time
SELECT order_date, total_sales,
       LAG(total_sales) OVER (ORDER BY order_date) AS previous_sales,
       LEAD(total_sales) OVER (ORDER BY order_date) AS next_sales
FROM orders;