SET NOCOUNT ON;
SET DEADLOCK_PRIORITY LOW;
SET LOCK_TIMEOUT 5000;

-- Server / FQDN (domain suffix read at runtime from the host's TCP/IP parameters; no client-specific literals baked into this script.)
DECLARE @MachineName varchar(128) = CAST(SERVERPROPERTY('MachineName') AS varchar(128));
DECLARE @FQDN varchar(300) = @MachineName;
DECLARE @DomainSuffix nvarchar(300) = NULL;

BEGIN TRY
    EXEC master.dbo.xp_regread
        @rootkey    = N'HKEY_LOCAL_MACHINE',
        @key        = N'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters',
        @value_name = N'Domain',
        @value      = @DomainSuffix OUTPUT;
END TRY
BEGIN CATCH
    SET @DomainSuffix = NULL;
END CATCH;

IF @DomainSuffix IS NOT NULL AND LEN(@DomainSuffix) > 0
    SET @FQDN = @MachineName + '.' + CAST(@DomainSuffix AS varchar(300));

-- Linked Servers
DECLARE @LinkedServerCount int = 0,
        @LinkedServerList nvarchar(max) = N'',
        @LinkedServerDependencyCount int = 0,
        @LinkedServerDependencyList nvarchar(max) = N'',
        @LinkedServerWarning nvarchar(4000) = N'';

-- SSIS
DECLARE @SSISCatalogPresent varchar(5) = 'FALSE',
        @SSISPackageCount int = 0,
        @SSISPackageList nvarchar(max) = N'',
        @LegacySSISPackageCount int = 0,
        @LegacySSISPackageList nvarchar(max) = N'',
        @SSISAgentJobStepCount int = 0,
        @SSISAgentJobList nvarchar(max) = N'',
        @SSISLastExecution datetimeoffset = NULL,
        @SSISActivePackages90d int = 0,
        @SSISTotalRuns90d int = 0,
        @SSISTopPackages90d nvarchar(max) = N'',
        @SSISWarning nvarchar(4000) = N'';

-- SSRS
DECLARE @SSRSReportServerPresent varchar(5) = 'FALSE',
        @SSRSReportCount int = 0,
        @SSRSReportList nvarchar(max) = N'',
        @SSRSSubscriptionCount int = 0,
        @SSRSSubscriptionList nvarchar(max) = N'',
        @SSRSLastSubscriptionRun datetime = NULL,
        @SSRSActiveReports90d int = 0,
        @SSRSTotalRuns90d int = 0,
        @SSRSTopReports90d nvarchar(max) = N'',
        @SSRSWarning nvarchar(4000) = N'';

-- Linked Server Discovery
BEGIN TRY
    SELECT @LinkedServerCount = COUNT(*)
    FROM sys.servers
    WHERE server_id <> 0 AND is_linked = 1;

    SELECT @LinkedServerList = ISNULL(
        STUFF((
            SELECT '; ' + s.name + ' [' + ISNULL(s.provider,'') + '] -> ' + ISNULL(s.data_source,'')
            FROM sys.servers s
            WHERE s.server_id <> 0 AND s.is_linked = 1
            ORDER BY s.name
            FOR XML PATH(''), TYPE
        ).value('.','nvarchar(max)'),1,2,''), N'');
END TRY
BEGIN CATCH
    SET @LinkedServerWarning = ERROR_MESSAGE();
END CATCH;


-- Linked Server Depdendencies

DECLARE @DB sysname,
        @SQL nvarchar(max),
        @DbDepCount int,
        @DbDepList nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND is_distributor = 0
  AND state_desc = 'ONLINE'
  AND (sys.fn_hadr_is_primary_replica(name) = 1
       OR sys.fn_hadr_is_primary_replica(name) IS NULL)
ORDER BY name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DB;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DbDepCount = 0;
    SET @DbDepList = N'';

    BEGIN TRY
        SET @SQL = N'
        USE ' + QUOTENAME(@DB) + N';

        SELECT @CountOUT = COUNT(*)
        FROM sys.sql_expression_dependencies
        WHERE referenced_server_name IS NOT NULL;

        SELECT @ListOUT = ISNULL(
            STUFF((
                SELECT ''; ''
                    + QUOTENAME(DB_NAME()) + ''.''
                    + ISNULL(QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)),''[?]'') + ''.''
                    + ISNULL(QUOTENAME(OBJECT_NAME(d.referencing_id)),''[?]'')
                    + '' -> ''
                    + ISNULL(QUOTENAME(d.referenced_server_name),''[?]'') + ''.''
                    + ISNULL(QUOTENAME(d.referenced_database_name),''[?]'') + ''.''
                    + ISNULL(QUOTENAME(d.referenced_schema_name),''[?]'') + ''.''
                    + ISNULL(QUOTENAME(d.referenced_entity_name),''[?]'')
                FROM sys.sql_expression_dependencies d
                WHERE d.referenced_server_name IS NOT NULL
                ORDER BY OBJECT_SCHEMA_NAME(d.referencing_id), OBJECT_NAME(d.referencing_id)
                FOR XML PATH(''''), TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');';

        EXEC sys.sp_executesql
            @SQL,
            N'@CountOUT int OUTPUT,@ListOUT nvarchar(max) OUTPUT',
            @CountOUT=@DbDepCount OUTPUT,
            @ListOUT=@DbDepList OUTPUT;

        SET @LinkedServerDependencyCount += ISNULL(@DbDepCount,0);

        IF NULLIF(@DbDepList,N'') IS NOT NULL
            SET @LinkedServerDependencyList =
                CASE WHEN @LinkedServerDependencyList = N''
                     THEN @DbDepList
                     ELSE @LinkedServerDependencyList + N'; ' + @DbDepList END;
    END TRY
    BEGIN CATCH
        SET @LinkedServerWarning =
            CASE WHEN @LinkedServerWarning = N''
                 THEN @DB + N': ' + ERROR_MESSAGE()
                 ELSE @LinkedServerWarning + N'; ' + @DB + N': ' + ERROR_MESSAGE() END;
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DB;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;


-- SSIS Discovery and Usage stats

IF DB_ID('SSISDB') IS NOT NULL
BEGIN
    SET @SSISCatalogPresent = 'TRUE';

    BEGIN TRY
        SET @SQL = N'
        DECLARE @Since datetimeoffset = DATEADD(day, -90, SYSDATETIMEOFFSET());

        SELECT @PackageCountOUT = COUNT(*)
        FROM SSISDB.catalog.packages;

        SELECT @PackageListOUT = ISNULL(
            STUFF((
                SELECT ''; '' + QUOTENAME(f.name) + ''/'' + QUOTENAME(p.name) + ''/'' + QUOTENAME(pkg.name)
                FROM SSISDB.catalog.folders f
                JOIN SSISDB.catalog.projects p ON f.folder_id = p.folder_id
                JOIN SSISDB.catalog.packages pkg ON p.project_id = pkg.project_id
                ORDER BY f.name,p.name,pkg.name
                FOR XML PATH(''''),TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');

        SELECT TOP (1) @LastExecutionOUT = start_time
        FROM SSISDB.catalog.executions
        ORDER BY execution_id DESC;

        SELECT @ActivePackages90dOUT = COUNT(DISTINCT e.folder_name + ''/'' + e.project_name + ''/'' + e.package_name),
               @TotalRuns90dOUT = COUNT_BIG(e.execution_id)
        FROM SSISDB.catalog.executions e
        WHERE e.start_time >= @Since;

        SELECT @TopPackages90dOUT = ISNULL(
            STUFF((
                SELECT ''; '' + t.pkg_full + '' ('' + CAST(t.run_count AS varchar(20)) + '' runs)''
                FROM (
                    SELECT TOP (5)
                        QUOTENAME(folder_name) + ''/'' + QUOTENAME(project_name) + ''/'' + QUOTENAME(package_name) AS pkg_full,
                        COUNT_BIG(*) AS run_count
                    FROM SSISDB.catalog.executions
                    WHERE start_time >= @Since
                    GROUP BY folder_name, project_name, package_name
                    ORDER BY COUNT_BIG(*) DESC
                ) t
                ORDER BY t.run_count DESC
                FOR XML PATH(''''),TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');';

        EXEC sys.sp_executesql
            @SQL,
            N'@PackageCountOUT int OUTPUT,@PackageListOUT nvarchar(max) OUTPUT,@LastExecutionOUT datetimeoffset OUTPUT,
              @ActivePackages90dOUT int OUTPUT,@TotalRuns90dOUT int OUTPUT,@TopPackages90dOUT nvarchar(max) OUTPUT',
            @PackageCountOUT=@SSISPackageCount OUTPUT,
            @PackageListOUT=@SSISPackageList OUTPUT,
            @LastExecutionOUT=@SSISLastExecution OUTPUT,
            @ActivePackages90dOUT=@SSISActivePackages90d OUTPUT,
            @TotalRuns90dOUT=@SSISTotalRuns90d OUTPUT,
            @TopPackages90dOUT=@SSISTopPackages90d OUTPUT;
    END TRY
    BEGIN CATCH
        SET @SSISWarning = ERROR_MESSAGE();
    END CATCH;
END;

-- SSIS Legacy Package

IF OBJECT_ID('msdb.dbo.sysssispackages') IS NOT NULL
BEGIN
    BEGIN TRY
        SELECT @LegacySSISPackageCount = COUNT(*)
        FROM msdb.dbo.sysssispackages;

        SELECT @LegacySSISPackageList = ISNULL(
            STUFF((
                SELECT '; ' + p.name
                FROM msdb.dbo.sysssispackages p
                ORDER BY p.name
                FOR XML PATH(''),TYPE
            ).value('.','nvarchar(max)'),1,2,''),N'');
    END TRY
    BEGIN CATCH
        SET @SSISWarning =
            CASE WHEN @SSISWarning = N''
                 THEN ERROR_MESSAGE()
                 ELSE @SSISWarning + N'; ' + ERROR_MESSAGE() END;
    END CATCH;
END;


-- SSIS SQL Agent jobs

BEGIN TRY
    SELECT @SSISAgentJobStepCount = COUNT(*)
    FROM msdb.dbo.sysjobsteps
    WHERE subsystem = 'SSIS';

    SELECT @SSISAgentJobList = ISNULL(
        STUFF((
            SELECT '; ' + j.name + ' / ' + s.step_name
            FROM msdb.dbo.sysjobs j
            JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
            WHERE s.subsystem = 'SSIS'
            ORDER BY j.name,s.step_id
            FOR XML PATH(''),TYPE
        ).value('.','nvarchar(max)'),1,2,''),N'');
END TRY
BEGIN CATCH
    SET @SSISWarning =
        CASE WHEN @SSISWarning = N''
             THEN ERROR_MESSAGE()
             ELSE @SSISWarning + N'; ' + ERROR_MESSAGE() END;
END CATCH;


-- SSRS Discovery and Usage stats

-- Detect both default (ReportServer) and named-instance (ReportServer$INSTANCE) catalog databases.
DECLARE @SSRSReportServerDb sysname = NULL;

SELECT TOP (1) @SSRSReportServerDb = name
FROM sys.databases
WHERE (name = N'ReportServer' OR name LIKE N'ReportServer$%')
  AND name NOT LIKE N'%TempDB'
ORDER BY name;

IF @SSRSReportServerDb IS NOT NULL
BEGIN
    SET @SSRSReportServerPresent = 'TRUE';

    BEGIN TRY
        SET @SQL = REPLACE(N'
        DECLARE @Since datetime = DATEADD(day, -90, GETDATE());

        SELECT @ReportCountOUT = COUNT(*)
        FROM {DB}.dbo.Catalog
        WHERE Type = 2;

        SELECT @ReportListOUT = ISNULL(
            STUFF((
                SELECT ''; '' + c.Path
                FROM {DB}.dbo.Catalog c
                WHERE c.Type = 2
                ORDER BY c.Path
                FOR XML PATH(''''),TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');

        SELECT @SubscriptionCountOUT = COUNT(*),
               @LastSubscriptionOUT = MAX(LastRunTime)
        FROM {DB}.dbo.Subscriptions;

        SELECT @SubscriptionListOUT = ISNULL(
            STUFF((
                SELECT ''; '' + c.Path + '' ['' + ISNULL(s.Description,'''') + '']''
                FROM {DB}.dbo.Subscriptions s
                JOIN {DB}.dbo.Catalog c ON s.Report_OID = c.ItemID
                ORDER BY c.Path
                FOR XML PATH(''''),TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');

        SELECT @ActiveReports90dOUT = COUNT(DISTINCT ItemPath),
               @TotalRuns90dOUT = COUNT_BIG(*)
        FROM {DB}.dbo.ExecutionLog3
        WHERE TimeStart >= @Since;

        SELECT @TopReports90dOUT = ISNULL(
            STUFF((
                SELECT ''; '' + t.ItemPath + '' ('' + CAST(t.run_count AS varchar(20)) + '' runs)''
                FROM (
                    SELECT TOP (5) ItemPath, COUNT_BIG(*) AS run_count
                    FROM {DB}.dbo.ExecutionLog3
                    WHERE TimeStart >= @Since
                    GROUP BY ItemPath
                    ORDER BY COUNT_BIG(*) DESC
                ) t
                ORDER BY t.run_count DESC
                FOR XML PATH(''''),TYPE
            ).value(''.'',''nvarchar(max)''),1,2,''''),N'''');',
            '{DB}', QUOTENAME(@SSRSReportServerDb));

        EXEC sys.sp_executesql
            @SQL,
            N'@ReportCountOUT int OUTPUT,@ReportListOUT nvarchar(max) OUTPUT,
              @SubscriptionCountOUT int OUTPUT,@SubscriptionListOUT nvarchar(max) OUTPUT,
              @LastSubscriptionOUT datetime OUTPUT,
              @ActiveReports90dOUT int OUTPUT,@TotalRuns90dOUT int OUTPUT,@TopReports90dOUT nvarchar(max) OUTPUT',
            @ReportCountOUT=@SSRSReportCount OUTPUT,
            @ReportListOUT=@SSRSReportList OUTPUT,
            @SubscriptionCountOUT=@SSRSSubscriptionCount OUTPUT,
            @SubscriptionListOUT=@SSRSSubscriptionList OUTPUT,
            @LastSubscriptionOUT=@SSRSLastSubscriptionRun OUTPUT,
            @ActiveReports90dOUT=@SSRSActiveReports90d OUTPUT,
            @TotalRuns90dOUT=@SSRSTotalRuns90d OUTPUT,
            @TopReports90dOUT=@SSRSTopReports90d OUTPUT;
    END TRY
    BEGIN CATCH
        SET @SSRSWarning = ERROR_MESSAGE();
    END CATCH;
END;

-- SQL / DB / File / AG metadata Discovery

;WITH ServerInfo AS
(
    SELECT
        osi.cpu_count AS LogicalCPUCount,
        osi.hyperthread_ratio AS HyperthreadRatio,
        CASE WHEN osi.hyperthread_ratio > 0
             THEN osi.cpu_count / osi.hyperthread_ratio
             ELSE osi.cpu_count END AS PhysicalCPUCount,
        CAST(cfg.value_in_use AS bigint) AS MaxServerMemoryMB
    FROM sys.dm_os_sys_info osi
    CROSS JOIN (
        SELECT value_in_use
        FROM sys.configurations
        WHERE name = 'max server memory (MB)'
    ) cfg
),
DatabaseInfo AS
(
    SELECT database_id,name AS DatabaseName,state_desc AS DatabaseStatus,compatibility_level
    FROM sys.databases
    WHERE database_id > 4 AND is_distributor = 0
),
DatabaseFiles AS
(
    SELECT
        database_id,
        CAST(SUM(CAST(size AS bigint))*8.0/1024 AS decimal(18,2)) AS DatabaseSizeMB,
        CAST(SUM(CASE WHEN type=0 THEN CAST(size AS bigint) ELSE 0 END)*8.0/1024 AS decimal(18,2)) AS DataSizeMB,
        CAST(SUM(CASE WHEN type=1 THEN CAST(size AS bigint) ELSE 0 END)*8.0/1024 AS decimal(18,2)) AS LogSizeMB,
        MAX(CASE WHEN growth>0 AND is_percent_growth=1 THEN 1 ELSE 0 END) AS PercentGrowthPresent
    FROM sys.master_files
    WHERE database_id > 4
    GROUP BY database_id
),
FileDetails AS
(
    SELECT
        d.database_id,

        ISNULL(STUFF((
            SELECT '; ' + mf.name + ' [' + mf.type_desc + '] Size='
                 + CONVERT(varchar(30),CAST(mf.size*8.0/1024 AS decimal(18,2))) + ' MB; Max='
                 + CASE WHEN mf.max_size=-1 THEN 'UNLIMITED'
                        WHEN mf.max_size=0 THEN 'NO GROWTH'
                        ELSE CONVERT(varchar(30),CAST(mf.max_size*8.0/1024 AS decimal(18,2))) + ' MB' END
                 + '; Growth='
                 + CASE WHEN mf.growth=0 THEN 'DISABLED'
                        WHEN mf.is_percent_growth=1 THEN CONVERT(varchar(20),mf.growth) + '%'
                        ELSE CONVERT(varchar(30),CAST(mf.growth*8.0/1024 AS decimal(18,2))) + ' MB' END
            FROM sys.master_files mf
            WHERE mf.database_id=d.database_id
            ORDER BY mf.type,mf.file_id
            FOR XML PATH(''),TYPE
        ).value('.','nvarchar(max)'),1,2,''),N'') AS FileConfiguration,

        ISNULL(STUFF((
            SELECT '; ' + mf.type_desc + ': ' + mf.physical_name
            FROM sys.master_files mf
            WHERE mf.database_id=d.database_id
            ORDER BY mf.type,mf.file_id
            FOR XML PATH(''),TYPE
        ).value('.','nvarchar(max)'),1,2,''),N'') AS PhysicalFilePaths

    FROM sys.databases d
    WHERE d.database_id > 4 AND d.is_distributor=0
),
SQLService AS
(
    SELECT ISNULL((
        SELECT TOP (1) status_desc
        FROM sys.dm_server_services
        WHERE servicename LIKE 'SQL Server (%' OR servicename='SQL Server'
        ORDER BY servicename
    ),'UNKNOWN') AS ServiceStatus
),
AGSubnet AS
(
    SELECT l.group_id,
           CASE WHEN COUNT(DISTINCT ip.network_subnet_ip)>1 THEN 'TRUE' ELSE 'FALSE' END AS IsMultiSubnet
    FROM sys.availability_group_listeners l
    JOIN sys.availability_group_listener_ip_addresses ip ON l.listener_id=ip.listener_id
    GROUP BY l.group_id
),
AGInfo AS
(
    SELECT
        drs.database_id,
        ag.group_id,
        ag.name AS AGName,
        ag.is_distributed,
        ar.replica_id,
        ar.replica_server_name,
        ar.availability_mode_desc,
        ars.role_desc,
        ars.operational_state_desc,
        drs.synchronization_state_desc,
        ISNULL(sn.IsMultiSubnet,'FALSE') AS IsMultiSubnet
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_groups ag ON drs.group_id=ag.group_id
    JOIN sys.availability_replicas ar ON drs.replica_id=ar.replica_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars
        ON drs.group_id=ars.group_id
       AND drs.replica_id=ars.replica_id
       AND ars.is_local=1
    LEFT JOIN AGSubnet sn ON ag.group_id=sn.group_id
    WHERE drs.is_local=1
)

SELECT
    @FQDN AS [Fully qualified domain name],
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS [Instance Name],

    db.DatabaseName AS [Database Name],
    db.DatabaseStatus AS [Database Status],
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS [SQL Edition],
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS [SQL Version],

    s.LogicalCPUCount AS [Logical CPU Count],
    s.HyperthreadRatio AS [Hyperthread Ratio],
    s.PhysicalCPUCount AS [Physical CPU Count],

    CASE WHEN SERVERPROPERTY('IsClustered')=1 THEN 'TRUE' ELSE 'FALSE' END AS [Is FCI Enabled],
    CASE WHEN SERVERPROPERTY('IsClustered')=1
         THEN CAST(SERVERPROPERTY('MachineName') AS nvarchar(128))
         ELSE '' END AS [Failover cluster name],

    s.MaxServerMemoryMB AS [Max server memory (in MB)],
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS [Service pack],

    CASE WHEN SERVERPROPERTY('IsHadrEnabled')=1 THEN 'TRUE' ELSE 'FALSE' END AS [IS AG enabled],
    svc.ServiceStatus AS [Service status],

    CASE WHEN ag.database_id IS NOT NULL THEN 'TRUE' ELSE 'FALSE' END AS [Is database highly available],

    f.DatabaseSizeMB AS [Database size (in MB)],
    f.DataSizeMB AS [Data file size (in MB)],
    f.LogSizeMB AS [Log file size (in MB)],
    db.compatibility_level AS [Compatibility level],

    CASE WHEN f.PercentGrowthPresent=1 THEN 'TRUE' ELSE 'FALSE' END AS [Percent growth files present],

    fd.FileConfiguration AS [Database file configuration],
    fd.PhysicalFilePaths AS [Database physical file paths],

    ISNULL(ag.AGName,'') AS [Availability group name],
    CASE WHEN ag.database_id IS NULL THEN ''
         WHEN ag.is_distributed=1 THEN 'DISTRIBUTED'
         ELSE 'REGULAR' END AS [Availability group type],

    ISNULL(ag.replica_server_name,'') AS [Availability replica name],
    ISNULL(ag.availability_mode_desc,'') AS [Commit mode],
    ISNULL(ag.role_desc,'') AS [Replica type],
    ISNULL(ag.operational_state_desc,'') AS [Replica state],
    ISNULL(ag.IsMultiSubnet,'FALSE') AS [Is AG multi subnet],
    ISNULL(ag.synchronization_state_desc,'') AS [AG replica sync status],

    @LinkedServerCount AS [Linked server count],
    @LinkedServerList AS [Linked servers],
    @LinkedServerDependencyCount AS [Linked server dependency count],
    @LinkedServerDependencyList AS [Linked server dependencies],
    @LinkedServerWarning AS [Linked server discovery warning],

    @SSISCatalogPresent AS [SSIS catalog present],
    @SSISPackageCount AS [SSIS package count],
    @SSISPackageList AS [SSIS packages],
    @LegacySSISPackageCount AS [Legacy SSIS package count],
    @LegacySSISPackageList AS [Legacy SSIS packages],
    @SSISAgentJobStepCount AS [SSIS SQL Agent job step count],
    @SSISAgentJobList AS [SSIS SQL Agent jobs],
    @SSISLastExecution AS [SSIS last execution],
    @SSISActivePackages90d AS [SSIS active packages (90d)],
    @SSISTotalRuns90d AS [SSIS executions (90d)],
    @SSISTopPackages90d AS [SSIS top packages (90d)],
    @SSISWarning AS [SSIS discovery warning],

    @SSRSReportServerPresent AS [SSRS ReportServer present],
    @SSRSReportCount AS [SSRS report count],
    @SSRSReportList AS [SSRS reports],
    @SSRSSubscriptionCount AS [SSRS subscription count],
    @SSRSSubscriptionList AS [SSRS subscriptions],
    @SSRSLastSubscriptionRun AS [SSRS last subscription run],
    @SSRSActiveReports90d AS [SSRS active reports (90d)],
    @SSRSTotalRuns90d AS [SSRS executions (90d)],
    @SSRSTopReports90d AS [SSRS top reports (90d)],
    @SSRSWarning AS [SSRS discovery warning]

FROM DatabaseInfo db
LEFT JOIN DatabaseFiles f ON db.database_id=f.database_id
LEFT JOIN FileDetails fd ON db.database_id=fd.database_id
LEFT JOIN AGInfo ag ON db.database_id=ag.database_id
CROSS JOIN ServerInfo s
CROSS JOIN SQLService svc

ORDER BY db.DatabaseName
OPTION (MAXDOP 1);