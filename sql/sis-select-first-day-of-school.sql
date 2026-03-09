declare @startdate varchar(20) = ( Select CONVERT(VARCHAR(20),[TRM].[D1],101) from trm where sc = 2 and tm = 'Y')
-- print  @startdate
SELECT @startdate as date