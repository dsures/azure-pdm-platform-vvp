SELECT
    (SELECT COUNT(*) FROM Machines) AS MachineCount,
    (SELECT COUNT(*) FROM MaintenanceHistory) AS MaintCount;