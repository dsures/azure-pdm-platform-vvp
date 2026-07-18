CREATE DATABASE PdMLegacy;
GO
USE PdMLegacy;
GO
CREATE TABLE Machines (
    machineID INT PRIMARY KEY,
    model VARCHAR(20),
    age INT
);
GO
CREATE TABLE MaintenanceHistory (
    datetime DATETIME,
    machineID INT,
    comp VARCHAR(10)
);
GO