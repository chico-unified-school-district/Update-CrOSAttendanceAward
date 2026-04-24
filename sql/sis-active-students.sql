SELECT
-- TOP 20
 s.ID,
 s.SC,
 CONVERT(VARCHAR(10), topEnr.ED, 23) as ED,
 s.SN
 -- ,s.GR
 -- ,s.LN
 -- ,s.FN
FROM STU AS s
 INNER JOIN
 (
-- Determine minimum Site Code min(sc) to prevent reprocessing loop
-- for students assigned to multiple school sites
   SELECT
    ID
    ,TG
    ,min(SC) AS minimumSiteCode
   FROM STU
   WHERE DEL = 0
    GROUP BY ID,TG having TG = ' '
 ) AS mainSite
 ON ( s.ID = mainSite.ID AND s.SC = mainSite.minimumSiteCode )
 LEFT JOIN (SELECT ID, MAX(ED) AS ED FROM ENR WHERE SC IN (VALID_SITE_CODES) GROUP BY ID) as topEnr ON s.ID = topEnr.ID
WHERE
(s.FN IS NOT NULL AND s.LN IS NOT NULL AND s.BD IS NOT NULL AND s.GR IS NOT NULL AND s.SC IS NOT NULL)
AND s.SC IN ( 5 )
-- AND s.SC IN ( VALID_SITE_CODES )
AND ( (s.DEL = 0) OR (s.DEL IS NULL) ) AND  ( s.TG = ' ' )
-- AND s.ID IN (12345) -- For testing
ORDER by s.ID;