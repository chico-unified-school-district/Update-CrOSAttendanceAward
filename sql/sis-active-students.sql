SELECT
 s.ID
 ,s.SC
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
     ,min(SC) AS minimumSitecode
    FROM STU
    WHERE DEL = 0
     GROUP BY ID,TG having TG = ' '
    ) AS gs
 ON ( s.ID = gs.ID AND s.SC = gs.minimumSitecode )
WHERE
(s.FN IS NOT NULL AND s.LN IS NOT NULL AND s.BD IS NOT NULL AND s.GR IS NOT NULL AND s.SC IS NOT NULL)
AND s.SC IN ( VALID_SITE_CODES )
AND ( (s.DEL = 0) OR (s.DEL IS NULL) ) AND  ( s.TG = ' ' )
-- AND s.ID = 12345 -- For testing
ORDER by s.ID;