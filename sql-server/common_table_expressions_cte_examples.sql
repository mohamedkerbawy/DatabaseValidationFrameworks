/*
Common Table Expressions (CTEs) in SQL Server (T-SQL)

Assumed tables used in some examples:
  Customers(CustomerID, CustomerName, Country)
  Orders(OrderID, CustomerID, OrderDate, TotalAmount, Status)
  OrderItems(OrderID, ProductID, Quantity, UnitPrice)
  Products(ProductID, ProductName, CategoryID, Cost)
  Employees(EmployeeID, EmployeeName, ManagerID, DepartmentID, Salary)

Run each example separately. Adjust table and column names to your schema.
*/

-- 1. Basic CTE: calculate total spending per customer
WITH CustomerSpending AS (
    SELECT
        CustomerID,
        SUM(TotalAmount) AS TotalSpent
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
)
SELECT CustomerID, TotalSpent
FROM CustomerSpending
ORDER BY TotalSpent DESC;


-- 2. Multiple CTEs: monthly revenue and its average
WITH MonthlySales AS (
    SELECT
        DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
        SUM(TotalAmount) AS Revenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
),
RevenueStats AS (
    SELECT
        AVG(Revenue) AS AverageMonthlyRevenue,
        MAX(Revenue) AS HighestMonthlyRevenue
    FROM MonthlySales
)
SELECT
    ms.SalesMonth,
    ms.Revenue,
    rs.AverageMonthlyRevenue,
    rs.HighestMonthlyRevenue
FROM MonthlySales AS ms
CROSS JOIN RevenueStats AS rs
ORDER BY ms.SalesMonth;


-- 3. CTE with a window function: rank customers by spending
WITH CustomerSpending AS (
    SELECT
        CustomerID,
        SUM(TotalAmount) AS TotalSpent
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
),
RankedCustomers AS (
    SELECT *,
        DENSE_RANK() OVER (ORDER BY TotalSpent DESC) AS SpendingRank
    FROM CustomerSpending
)
SELECT *
FROM RankedCustomers
ORDER BY SpendingRank, CustomerID;


-- 4. Filter an aggregate using a CTE: customers spending above $1,000
-- Change the threshold and currency to suit your data.
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
WHERE TotalSpent > 1000
ORDER BY TotalSpent DESC;


-- 5. Find customers with no completed orders
WITH CustomersWithCompletedOrders AS (
    SELECT DISTINCT CustomerID
    FROM Orders
    WHERE Status = 'Completed'
)
SELECT c.CustomerID, c.CustomerName
FROM Customers AS c
LEFT JOIN CustomersWithCompletedOrders AS x
    ON x.CustomerID = c.CustomerID
WHERE x.CustomerID IS NULL;


-- 6. Find the latest order per customer
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


-- 7. Recursive CTE: employee reporting hierarchy
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


-- 8. Recursive CTE: generate a sequence of integers from 1 to 10
WITH NumberSequence AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1
    FROM NumberSequence
    WHERE n < 10
)
SELECT n
FROM NumberSequence
OPTION (MAXRECURSION 100);


-- 9. Recursive CTE: generate calendar dates for a range
-- Change the start and end dates as needed.
DECLARE @StartDate date = '2026-01-01';
DECLARE @EndDate   date = '2026-01-31';

WITH Calendar AS (
    SELECT @StartDate AS CalendarDate
    WHERE @StartDate <= @EndDate

    UNION ALL

    SELECT DATEADD(DAY, 1, CalendarDate)
    FROM Calendar
    WHERE CalendarDate < @EndDate
)
SELECT CalendarDate
FROM Calendar
ORDER BY CalendarDate
OPTION (MAXRECURSION 0);


-- 10. Compare each customer's orders with their average order value
WITH CustomerOrderStats AS (
    SELECT
        CustomerID,
        AVG(TotalAmount) AS AverageOrderValue,
        COUNT(*) AS OrderCount
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
)
SELECT
    o.OrderID,
    o.CustomerID,
    o.OrderDate,
    o.TotalAmount,
    s.AverageOrderValue,
    o.TotalAmount - s.AverageOrderValue AS DifferenceFromAverage
FROM Orders AS o
JOIN CustomerOrderStats AS s
    ON s.CustomerID = o.CustomerID
WHERE o.Status = 'Completed'
ORDER BY o.CustomerID, o.OrderDate;


-- 11. CTE for product revenue and contribution percentage
WITH ProductRevenue AS (
    SELECT
        p.ProductID,
        p.ProductName,
        SUM(oi.Quantity * oi.UnitPrice) AS Revenue
    FROM Products AS p
    JOIN OrderItems AS oi
        ON oi.ProductID = p.ProductID
    GROUP BY p.ProductID, p.ProductName
),
RevenueWithShare AS (
    SELECT *,
        100.0 * Revenue / NULLIF(SUM(Revenue) OVER (), 0) AS RevenueSharePercent
    FROM ProductRevenue
)
SELECT *
FROM RevenueWithShare
ORDER BY Revenue DESC;


-- 12. Find consecutive order days per customer
WITH OrderDays AS (
    SELECT DISTINCT
        CustomerID,
        CAST(OrderDate AS date) AS OrderDay
    FROM Orders
    WHERE Status = 'Completed'
),
OrderDaySequence AS (
    SELECT *,
        LAG(OrderDay) OVER (
            PARTITION BY CustomerID
            ORDER BY OrderDay
        ) AS PreviousOrderDay
    FROM OrderDays
)
SELECT *
FROM OrderDaySequence
WHERE DATEDIFF(DAY, PreviousOrderDay, OrderDay) = 1;


-- 13. Find products whose revenue is above the average product revenue
WITH ProductRevenue AS (
    SELECT
        p.ProductID,
        p.ProductName,
        SUM(oi.Quantity * oi.UnitPrice) AS Revenue
    FROM Products AS p
    JOIN OrderItems AS oi
        ON oi.ProductID = p.ProductID
    GROUP BY p.ProductID, p.ProductName
),
RevenueStats AS (
    SELECT AVG(Revenue) AS AverageProductRevenue
    FROM ProductRevenue
)
SELECT pr.*
FROM ProductRevenue AS pr
CROSS JOIN RevenueStats AS rs
WHERE pr.Revenue > rs.AverageProductRevenue
ORDER BY pr.Revenue DESC;


-- 14. CTE with conditional aggregation: monthly order status counts
WITH MonthlyStatus AS (
    SELECT
        DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS SalesMonth,
        SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END) AS CompletedOrders,
        SUM(CASE WHEN Status = 'Pending' THEN 1 ELSE 0 END) AS PendingOrders,
        SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END) AS CancelledOrders
    FROM Orders
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
)
SELECT *
FROM MonthlyStatus
ORDER BY SalesMonth;


-- 15. CTE to identify possible duplicate orders
-- This flags identical customer, date, and amount combinations for review;
-- it does not prove that the orders are duplicates.
WITH PossibleDuplicates AS (
    SELECT
        CustomerID,
        CAST(OrderDate AS date) AS OrderDay,
        TotalAmount,
        COUNT(*) AS MatchingOrders
    FROM Orders
    GROUP BY CustomerID, CAST(OrderDate AS date), TotalAmount
    HAVING COUNT(*) > 1
)
SELECT *
FROM PossibleDuplicates
ORDER BY MatchingOrders DESC, CustomerID;


-- 16. Use a CTE to calculate customer lifetime value (simple historical revenue)
WITH CustomerLifetimeValue AS (
    SELECT
        c.CustomerID,
        c.CustomerName,
        COUNT(o.OrderID) AS CompletedOrderCount,
        COALESCE(SUM(o.TotalAmount), 0) AS LifetimeRevenue
    FROM Customers AS c
    LEFT JOIN Orders AS o
        ON o.CustomerID = c.CustomerID
       AND o.Status = 'Completed'
    GROUP BY c.CustomerID, c.CustomerName
)
SELECT *
FROM CustomerLifetimeValue
ORDER BY LifetimeRevenue DESC;


-- 17. CTE to calculate category sales by month
WITH CategoryMonthlySales AS (
    SELECT
        p.CategoryID,
        DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS SalesMonth,
        SUM(oi.Quantity * oi.UnitPrice) AS Revenue
    FROM Orders AS o
    JOIN OrderItems AS oi
        ON oi.OrderID = o.OrderID
    JOIN Products AS p
        ON p.ProductID = oi.ProductID
    WHERE o.Status = 'Completed'
    GROUP BY
        p.CategoryID,
        YEAR(o.OrderDate),
        MONTH(o.OrderDate)
)
SELECT *
FROM CategoryMonthlySales
ORDER BY CategoryID, SalesMonth;


-- 18. CTE to find each customer's first completed order
WITH FirstOrders AS (
    SELECT
        CustomerID,
        MIN(OrderDate) AS FirstOrderDate
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID
)
SELECT
    c.CustomerID,
    c.CustomerName,
    f.FirstOrderDate
FROM FirstOrders AS f
JOIN Customers AS c
    ON c.CustomerID = f.CustomerID
ORDER BY f.FirstOrderDate;


-- 19. CTE to calculate running revenue by customer
WITH CustomerDailyRevenue AS (
    SELECT
        CustomerID,
        CAST(OrderDate AS date) AS OrderDay,
        SUM(TotalAmount) AS DailyRevenue
    FROM Orders
    WHERE Status = 'Completed'
    GROUP BY CustomerID, CAST(OrderDate AS date)
)
SELECT *,
    SUM(DailyRevenue) OVER (
        PARTITION BY CustomerID
        ORDER BY OrderDay
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS CustomerRunningRevenue
FROM CustomerDailyRevenue
ORDER BY CustomerID, OrderDay;


-- 20. CTE to calculate salary ranking within each department
WITH DepartmentSalaryRanks AS (
    SELECT
        EmployeeID,
        EmployeeName,
        DepartmentID,
        Salary,
        DENSE_RANK() OVER (
            PARTITION BY DepartmentID
            ORDER BY Salary DESC
        ) AS DepartmentSalaryRank,
        AVG(Salary) OVER (
            PARTITION BY DepartmentID
        ) AS DepartmentAverageSalary
    FROM Employees
)
SELECT *
FROM DepartmentSalaryRanks
ORDER BY DepartmentID, DepartmentSalaryRank, EmployeeID;


/*
CTE reminders:
1. A CTE starts with WITH and is followed immediately by one statement.
2. In SQL Server, place a semicolon before WITH if the preceding statement
   in the same batch is not already terminated.
3. A CTE is not automatically materialized; the optimizer chooses the plan.
4. Recursive CTEs need an anchor member and a recursive member joined by UNION ALL.
5. CTEs are scoped to the single statement immediately following them.
*/
