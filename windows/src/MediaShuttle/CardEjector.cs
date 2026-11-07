using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MediaShuttle;

/// <summary>
/// Ejects a card the way Explorer's Eject command does. A card in a reader Windows reports as
/// removable is dismounted and its media ejected, which leaves the reader's drive letter showing no
/// media. Many USB readers report a fixed disk instead, and those are removed as a device, which is
/// what Safely Remove Hardware does.
/// </summary>
internal static class CardEjector
{
    public static bool IsEjectable(string rootPath)
    {
        try
        {
            string root = Path.GetFullPath(rootPath);
            string? volumeRoot = Path.GetPathRoot(root);
            if (volumeRoot is null || volumeRoot.Length != 3 || volumeRoot[1] != ':' ||
                !Path.TrimEndingDirectorySeparator(root).Equals(
                    Path.TrimEndingDirectorySeparator(volumeRoot), StringComparison.OrdinalIgnoreCase) ||
                volumeRoot.Equals(Path.GetPathRoot(Environment.SystemDirectory), StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            return new DriveInfo(volumeRoot).DriveType is DriveType.Removable or DriveType.Fixed;
        }
        catch (Exception exception) when (exception is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public static void Eject(string rootPath)
    {
        string volumeRoot = Path.GetPathRoot(Path.GetFullPath(rootPath))
            ?? throw new IOException("This isn't a drive that can be ejected.");
        string volumePath = @"\\.\" + volumeRoot.TrimEnd('\\');
        bool removable = new DriveInfo(volumeRoot).DriveType == DriveType.Removable;

        uint diskNumber;
        using (SafeFileHandle volume = Open(volumePath, GenericRead | GenericWrite))
        {
            LockAndDismount(volume);
            if (removable)
            {
                if (!TryEjectMedia(volume))
                {
                    throw new IOException("Windows couldn't eject the card.", new Win32Exception(Marshal.GetLastWin32Error()));
                }
                return;
            }
            diskNumber = DeviceNumber(volume);
        }

        // Fixed USB disks don't take a media eject. Ask Windows to remove the device the disk is
        // attached to. The volume handle is closed first: an open handle vetoes the removal.
        RequestDeviceRemoval(diskNumber);
    }

    private static void LockAndDismount(SafeFileHandle volume)
    {
        // Explorer windows and indexers let go of a volume within a moment of being asked; a
        // few retries ride that out without making the person try again.
        for (int attempt = 0; ; attempt++)
        {
            if (DeviceIoControl(volume, FsctlLockVolume, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero))
            {
                break;
            }
            if (attempt == 9)
            {
                throw new IOException(
                    "The card is in use. Close any app or File Explorer window using it, then try again.",
                    new Win32Exception(Marshal.GetLastWin32Error()));
            }
            Thread.Sleep(300);
        }

        if (!DeviceIoControl(volume, FsctlDismountVolume, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero))
        {
            throw new IOException("Windows couldn't dismount the card.", new Win32Exception(Marshal.GetLastWin32Error()));
        }
    }

    private static bool TryEjectMedia(SafeFileHandle volume)
    {
        IntPtr allowRemoval = Marshal.AllocHGlobal(1);
        try
        {
            Marshal.WriteByte(allowRemoval, 0);
            DeviceIoControl(volume, IoctlStorageMediaRemoval, allowRemoval, 1, IntPtr.Zero, 0, out _, IntPtr.Zero);
        }
        finally
        {
            Marshal.FreeHGlobal(allowRemoval);
        }
        return DeviceIoControl(volume, IoctlStorageEjectMedia, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
    }

    private static uint DeviceNumber(SafeFileHandle device)
    {
        int size = Marshal.SizeOf<StorageDeviceNumber>();
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!DeviceIoControl(device, IoctlStorageGetDeviceNumber, IntPtr.Zero, 0, buffer, (uint)size, out _, IntPtr.Zero))
            {
                throw new IOException("Windows couldn't identify the card's disk.", new Win32Exception(Marshal.GetLastWin32Error()));
            }
            return Marshal.PtrToStructure<StorageDeviceNumber>(buffer).DeviceNumber;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void RequestDeviceRemoval(uint diskNumber)
    {
        Guid diskInterface = GuidDevinterfaceDisk;
        IntPtr deviceSet = SetupDiGetClassDevs(ref diskInterface, IntPtr.Zero, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
        if (deviceSet == InvalidHandleValue)
        {
            throw new IOException("Windows couldn't list disks.", new Win32Exception(Marshal.GetLastWin32Error()));
        }

        try
        {
            for (uint index = 0; ; index++)
            {
                var interfaceData = new SpDeviceInterfaceData { Size = Marshal.SizeOf<SpDeviceInterfaceData>() };
                if (!SetupDiEnumDeviceInterfaces(deviceSet, IntPtr.Zero, ref diskInterface, index, ref interfaceData))
                {
                    break;
                }

                var deviceData = new SpDevinfoData { Size = Marshal.SizeOf<SpDevinfoData>() };
                string? devicePath = InterfacePath(deviceSet, ref interfaceData, ref deviceData);
                if (devicePath is null)
                {
                    continue;
                }

                uint number;
                try
                {
                    using SafeFileHandle disk = Open(devicePath, 0);
                    number = DeviceNumber(disk);
                }
                catch (IOException)
                {
                    continue;
                }
                if (number != diskNumber)
                {
                    continue;
                }

                if (CM_Get_Parent(out uint parent, deviceData.DevInst, 0) != CrSuccess)
                {
                    throw new IOException("Windows couldn't find the device the card is in.");
                }

                // The first refusal is often an Explorer window that closes itself on the
                // notification this sends, so one retry is worth it.
                for (int attempt = 0; attempt < 2; attempt++)
                {
                    var vetoName = new StringBuilder(MaxPath);
                    int result = CM_Request_Device_Eject(parent, out int vetoType, vetoName, MaxPath, 0);
                    if (result == CrSuccess && vetoType == 0)
                    {
                        return;
                    }
                    Thread.Sleep(500);
                }
                throw new IOException("The card is in use. Close any app or File Explorer window using it, then try again.");
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(deviceSet);
        }

        throw new IOException("Windows couldn't find the device the card is in.");
    }

    private static string? InterfacePath(IntPtr deviceSet, ref SpDeviceInterfaceData interfaceData, ref SpDevinfoData deviceData)
    {
        SetupDiGetDeviceInterfaceDetail(deviceSet, ref interfaceData, IntPtr.Zero, 0, out uint required, IntPtr.Zero);
        if (required == 0)
        {
            return null;
        }

        IntPtr detail = Marshal.AllocHGlobal((int)required);
        try
        {
            // cbSize is the size of the fixed part of SP_DEVICE_INTERFACE_DETAIL_DATA_W: a DWORD
            // and one WCHAR, padded to 8 on 64-bit.
            Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
            if (!SetupDiGetDeviceInterfaceDetail(deviceSet, ref interfaceData, detail, required, out _, ref deviceData))
            {
                return null;
            }
            return Marshal.PtrToStringUni(detail + 4);
        }
        finally
        {
            Marshal.FreeHGlobal(detail);
        }
    }

    private static SafeFileHandle Open(string path, uint access)
    {
        SafeFileHandle handle = CreateFile(path, access, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("Windows couldn't open the card.", new Win32Exception(error));
        }
        return handle;
    }

    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x1;
    private const uint FileShareWrite = 0x2;
    private const uint OpenExisting = 3;
    private const uint FsctlLockVolume = 0x00090018;
    private const uint FsctlDismountVolume = 0x00090020;
    private const uint IoctlStorageMediaRemoval = 0x002D4804;
    private const uint IoctlStorageEjectMedia = 0x002D4808;
    private const uint IoctlStorageGetDeviceNumber = 0x002D1080;
    private const uint DigcfPresent = 0x2;
    private const uint DigcfDeviceInterface = 0x10;
    private const int CrSuccess = 0;
    private const int MaxPath = 260;
    private static readonly IntPtr InvalidHandleValue = new(-1);
    private static readonly Guid GuidDevinterfaceDisk = new("53f56307-b6bf-11d0-94f2-00a0c91efb8b");

    [StructLayout(LayoutKind.Sequential)]
    private struct StorageDeviceNumber
    {
        public uint DeviceType;
        public uint DeviceNumber;
        public uint PartitionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInterfaceData
    {
        public int Size;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDevinfoData
    {
        public int Size;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    private static extern SafeFileHandle CreateFile(
        string fileName, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device, uint code, IntPtr inBuffer, uint inSize, IntPtr outBuffer, uint outSize,
        out uint returned, IntPtr overlapped);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupDiGetClassDevsW")]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr parent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr deviceSet, IntPtr deviceInfo, ref Guid interfaceGuid, uint index, ref SpDeviceInterfaceData interfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupDiGetDeviceInterfaceDetailW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr deviceSet, ref SpDeviceInterfaceData interfaceData, IntPtr detail, uint detailSize, out uint required, IntPtr deviceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupDiGetDeviceInterfaceDetailW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr deviceSet, ref SpDeviceInterfaceData interfaceData, IntPtr detail, uint detailSize, out uint required, ref SpDevinfoData deviceData);

    [DllImport("setupapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceSet);

    [DllImport("cfgmgr32.dll")]
    private static extern int CM_Get_Parent(out uint parent, uint devInst, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, EntryPoint = "CM_Request_Device_EjectW")]
    private static extern int CM_Request_Device_Eject(
        uint devInst, out int vetoType, StringBuilder vetoName, int vetoNameLength, uint flags);
}
