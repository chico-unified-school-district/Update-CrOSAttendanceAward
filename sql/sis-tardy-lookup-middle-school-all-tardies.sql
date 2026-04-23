SELECT TOP 1 ID,AC,DT
FROM [CAT]
WHERE
DEL = 0
and (AC not in ('', 'D','F','G','H','I','M','N','O','P','Q','R','T','U','V','W','Y','Z'))
and ID = @permId
ORDER BY DT DESC;

-- SELECT
--     StudentID,
--     MAX(TardyDate) AS LatestTardyDate
-- FROM
--     StudentAttendance
-- GROUP BY
--     StudentID;
