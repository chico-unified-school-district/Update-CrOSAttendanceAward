SELECT TOP 1 SN,AL,DT
FROM [ATT]
WHERE
DEL = 0
and (AL not in ('', 'D','F','G','H','I','M','N','O','P','Q','R','T','U','V','W','Y','Z'))
and SN = @sn
ORDER BY DT DESC;
