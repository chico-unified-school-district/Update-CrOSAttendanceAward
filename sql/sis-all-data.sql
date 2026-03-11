declare  @SchoolYear as varchar(20)=  DATEPART(year,( Select  CONVERT(VARCHAR(10),[TRM].[D1],101) from trm where sc = 2 and tm = 'Y'))
print @SchoolYear
declare @streakdate as date = '2025-03-03'
--AND (CAT.DT < =GETDATE() AND CAT.DT >= '2026-02-25') --Feb25 10day
--AND (CAT.DT <= GETDATE()  AND CAT.DT >= '2026-01-26')  --jan26  30 days
--AND (CAT.DT <=GETDATE()  AND CAT.DT >= '2025-12-11') --  dec 11 50 day
--AND (CAT.DT <= GETDATE()  AND CAT.DT >= '2025-10-15') --oct 15  80 days

SELECT  distinct [STU].[ID] AS [Student ID],
 CONVERT(VARCHAR(10),[ENR].[ED],101) AS [school Enter Date],
 [CAT].[ID] AS [Student ID1],
 CONVERT(VARCHAR(10),[CAT].[DT],101) AS [missing Date],
 [DRI].[SR] AS [Serial Number],
 [DRI].[BC] AS [Bar Code]
 FROM

 ((SELECT [DRA].* FROM [DRA] WHERE DEL = 0 and DRA.RID= 1 and ( DRA.CD ='' or DRA.CD='V') and DRA.RD is NULL) [DRA] left JOIN (SELECT [DRI].* FROM [DRI] WHERE DEL = 0)[DRI]  ON [DRI].[RID] = [DRA].[RID] AND [DRI].[RIN] = [DRA].[RIN])
  RIGHT JOIN

  ((SELECT [CAT].* FROM [CAT] WHERE DEL = 0) [CAT] RIGHT JOIN

  ((SELECT [STU].* FROM STU WHERE DEL = 0 and stu.tg = ' ' ) [STU]
 LEFT JOIN (SELECT [ENR].* FROM [ENR] WHERE DEL = 0) [ENR] ON [STU].[SN] = [ENR].[SN] and STU.SC = ENR.SC and  STU.GR = ENR.GR and CAST(ENR.YR as varchar(20)) =  @SchoolYear
 )
 ON [STU].[ID] = [CAT].[ID])

 ON  DRA.ID = STU.ID

  WHERE (NOT STU.TG > ' ') AND [STU].SC in ( 5)
AND DRA.RID = 1
  and (CAT.AC NOT IN ('', 'D','F','H','I','M','N','O','P','Q','R','T','U','V','W','Y','Z'))
AND (CAT.DT < =GETDATE() AND CAT.DT  >=  @streakdate) -- Marh 3    5day
-- AND ENR.ED != '08/19/2025'
-- AND stu.id = 12345 -- For testing
  ORDER BY [STU].[ID]