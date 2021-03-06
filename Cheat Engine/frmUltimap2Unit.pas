unit frmUltimap2Unit;

{$mode objfpc}{$H+}



interface

uses
  windows, Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs,
  ExtCtrls, StdCtrls, ComCtrls, EditBtn, Menus, libipt, ProcessHandlerUnit,
  DBK32functions, commonTypeDefs, MemFuncs, AvgLvlTree, Math, FileMapping,
  syncobjs;


const
  bifInvalidated=1;
  bifExecuted=2;
  bifIsCall=4;

type
  TRecordState=(rsStopped, rsProcessing, rsRecording);
  TFilterOption=(foNone, foExecuted, foNotExecuted, foNonCALLInstructions, foExecuteCountLowerThan, foNotInRange, foResetAll);

  TByteInfo=packed record
    count: byte;
    flags: byte;
  end;
  PByteInfo=^TByteInfo;

  TRegionInfo=record
    address: ptruint;
    memory: PByte;
    size: integer;

    info: PByteInfo;

  end;
  PRegionInfo=^TRegionInfo;

  TfrmUltimap2=class;

  TUltimap2Worker=class(TThread) //many
  private
    lastRegion: PRegionInfo;

    filemap: TFileMapping;
    function addIPPageToRegionTree(IP: QWORD): PRegionInfo;
    function addIPBlockToRegionTree(IP: QWORD): PRegionInfo;
    procedure HandleIP(ip: QWORD; c: pt_insn_class);
    procedure HandleIPForRegion(ip: qword; c: pt_insn_class; region: PRegionInfo);

    function waitForData(timeout: dword; var e: TUltimap2DataEvent): boolean;
    procedure continueFromData(e: TUltimap2DataEvent);
  public
    id: integer;
    filename: string;
    fromFile: boolean;
    processFile: TEvent;
    done: boolean;
    ownerForm: TfrmUltimap2;

    processed: qword;
    totalsize: qword;

    procedure execute; override;

    constructor create(CreateSuspended: boolean);
    destructor destroy; override;
  end;

  TUltimap2FilterThread=class(tthread) //1
  private
    procedure EnableGUI;
  public
    ownerForm: TfrmUltimap2;
    filteroption: TfilterOption;
    callcount: integer;
    rangestart, rangestop: qword;
    ExcludeFuturePaths: boolean;

    procedure execute; override;
  end;


  { TfrmUltimap2 }

  TfrmUltimap2 = class(TForm)
    btnExecuted: TButton;
    btnFilterCallCount: TButton;
    btnFilterModule: TButton;
    btnNotCalled: TButton;
    btnAddRange: TButton;
    btnNotExecuted: TButton;
    btnResetCount: TButton;
    btnRecordPause: TButton;
    btnCancelFilter: TButton;
    Button5: TButton;
    btnReset: TButton;
    cbFilterFuturePaths: TCheckBox;
    cbfilterOutNewEntries: TCheckBox;
    edtCallCount: TEdit;
    gbRange: TGroupBox;
    Label1: TLabel;
    lblLastfilterresult: TLabel;
    lbRange: TListBox;
    miRangeDeleteSelected: TMenuItem;
    miRangeDeleteAll: TMenuItem;
    Panel1: TPanel;
    Panel4: TPanel;
    pmRangeOptions: TPopupMenu;
    rbLogToFolder: TRadioButton;
    rbRuntimeParsing: TRadioButton;
    deTargetFolder: TDirectoryEdit;
    edtBufSize: TEdit;
    lblBuffersPerCPU: TLabel;
    Label3: TLabel;
    lblKB: TLabel;
    lblIPCount: TLabel;
    ListView1: TListView;
    Panel2: TPanel;
    Panel3: TPanel;
    Panel5: TPanel;
    tActivator: TTimer;
    procedure btnAddRangeClick(Sender: TObject);
    procedure btnExecutedClick(Sender: TObject);
    procedure btnFilterCallCountClick(Sender: TObject);
    procedure btnFilterModuleClick(Sender: TObject);
    procedure btnNotCalledClick(Sender: TObject);
    procedure btnNotExecutedClick(Sender: TObject);
    procedure btnCancelFilterClick(Sender: TObject);
    procedure btnResetClick(Sender: TObject);
    procedure cbfilterOutNewEntriesChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure miRangeDeleteSelectedClick(Sender: TObject);
    procedure miRangeDeleteAllClick(Sender: TObject);
    procedure Panel5Click(Sender: TObject);
    procedure tActivatorTimer(Sender: TObject);
    procedure tbRecordPauseChange(Sender: TObject);
  private
    { private declarations }
    l: tstringlist;
    ultimap2Initialized: dword;

    regiontree: TAvgLvlTree;
    regiontreeMREW: TMultiReadExclusiveWriteSynchronizer;

    workers: array of TUltimap2Worker;

    fstate: TRecordState;
    PostProcessingFilter: TFilterOption; //called when all threads enter the done state
    Filtercount: byte;
    FilterRangeFrom, FilterRangeTo: qword;

    filterThread: TUltimap2FilterThread;

    filterExcludeFuturePaths: boolean;

    function RegionCompare(Tree: TAvgLvlTree; Data1, Data2: pointer): integer;

    procedure freeRegion(r: PRegionInfo);
    procedure cleanup;
    procedure setConfigGUIState(state: boolean);
    procedure enableConfigGUI;
    procedure disableConfigGUI;

    procedure FilterGUI(state: boolean);
    procedure Filter(filterOption: TFilterOption);
    procedure FlushResults(f: TFilterOption=foNone);
    procedure ExecuteFilter(Sender: TObject);

    procedure setState(state: TRecordState);
    function ModuleSelectEvent(index: integer; listText: string): string;
    property state:TRecordState read fstate write setState;
  public
    { public declarations }
    allNewAreInvalid: boolean;

  end;

var
  frmUltimap2: TfrmUltimap2;

implementation

{$R *.lfm}

uses symbolhandler, frmSelectionlistunit, cpuidUnit;

//worker




function iptReadMemory(buffer: PByteArray; size: SIZE_T; asid: PPT_ASID; ip: uint64; context: pointer): integer; cdecl;
var self: TUltimap2Worker;
  n: TAvgLvlTreeNode;
  e: TRegionInfo;

  s: integer;
begin
  self:=TUltimap2Worker(context);
  //watch for page boundaries

  if (self.lastRegion=nil) or (ip<self.lastRegion^.address) or (ip>=(self.lastRegion^.address+self.lastRegion^.size)) then
  begin
    e.address:=ip;
    self.ownerForm.regiontreeMREW.Beginread;
    n:=self.ownerForm.regiontree.Find(@e);
    self.ownerForm.regiontreeMREW.endRead;


    if n<>nil then
      self.lastRegion:=PRegionInfo(n.Data)
    else
    begin
      //self.lastRegion:=nil;
      self.lastregion:=self.addIPBlockToRegionTree(ip);
      if self.lastregion=nil then
        exit(-integer(pte_nomap));
    end;
  end;

  if self.lastRegion<>nil then
  begin
    s:=(self.lastRegion^.address+self.lastRegion^.size)-ip;
    if s>size then s:=size;
    CopyMemory(buffer, @self.lastRegion^.memory[ip-self.lastRegion^.address], s);

    size:=size-s;
    if size>0 then
    begin
      ip:=ip+s;
      s:=s+iptReadMemory(@buffer^[s], size, asid, ip, context);
    end
    else
      result:=s;
  end;


end;

function TUltimap2Worker.addIPPageToRegionTree(IP: QWORD): PRegionInfo;
//Write lock must be obtained beforehand
var
  page: pbyte;
  baseaddress: ptruint;
  br: ptruint;

  p: PRegionInfo;
begin
  result:=nil;
  baseaddress:=ip and (not qword($fff));

  getmem(page,4096);
  if ReadProcessMemory(processhandle, pointer(baseaddress),page, 4096, br) then
  begin
    //successful read, add it
    getmem(p, sizeof(TRegionInfo));
    p^.address:=baseaddress;
    p^.size:=br;
    p^.memory:=page;
    getmem(p^.info, 4096*sizeof(TByteInfo));

    if ownerform.allNewAreInvalid then
      FillMemory(p^.info, p^.size, $ff) //marks it as filtered out
    else
      zeromemory(p^.info, p^.size*sizeof(TByteInfo));

    ownerForm.regiontree.Add(p);
    result:=p;
  end
  else
    freemem(page);
end;

function TUltimap2Worker.addIPBlockToRegionTree(IP: QWORD): PRegionInfo;
var
  e: TRegionInfo;
  p: PRegionInfo;
  baseaddress: ptruint;
  currentAddress, endaddress: ptruint;
  mbi: TMemoryBasicInformation;
  i: integer;
  br: ptruint;
begin
  //read the memory and add it if necesary
  result:=nil;

  ownerForm.regiontreeMREW.Beginwrite;

  try
    e.address:=ip;
    if ownerForm.regiontree.Find(@e)<>nil then exit; //something else already added it

    //find which pages are in and which ones are not.  Scan till a page is inside a region, or until a memory address is not found

    baseaddress:=ip and (not qword($fff));

    if VirtualQueryEx(processhandle, pointer(baseaddress), mbi, sizeof(mbi))=sizeof(mbi) then
    begin
      if mbi.State=MEM_COMMIT then
      begin
        currentAddress:=baseaddress+4096;
        while currentAddress<endaddress do //scan till the end and see if it's in the list
        begin
          e.address:=currentAddress;

          if ownerForm.regiontree.Find(@e)<>nil then //found something
            break;

          inc(currentAddress,4096);
        end;

        endaddress:=currentAddress;

        //scan backwards (using virtualqueryex and the regiontree)
        i:=0;
        currentaddress:=baseaddress-4096;
        while (VirtualQueryEx(processhandle, pointer(baseaddress), mbi, sizeof(mbi))=sizeof(mbi)) and (i<16) do
        begin
          if mbi.State<>MEM_COMMIT then
            break;

          e.address:=currentAddress;
          if ownerForm.regiontree.Find(@e)<>nil then //found something
            break;

          dec(currentAddress, 4096);
          inc(i);
        end;

        baseaddress:=currentaddress+4096;

        //allocate memory for this and fill it

        getmem(p, sizeof(TRegionInfo));
        p^.address:=baseaddress;
        p^.size:=endaddress-baseaddress;
        getmem(p^.memory, p^.size);
        getmem(p^.info, p^.size*sizeof(TByteInfo));


        br:=0;
        ReadProcessMemory(processhandle, pointer(baseaddress),p^.memory, p^.size, br);
        if br<endaddress-baseaddress then
        begin
          p^.size:=br; //fix size

          if (br=0) or (ip>(baseaddress+br)) then //failure. Try a single page
          begin
            ownerForm.freeRegion(p);
            exit(addIPPageToRegionTree(IP));
          end;
        end;

        if ownerform.allNewAreInvalid then
          FillMemory(p^.info, p^.size, $ff)
        else
          zeromemory(p^.info, p^.size*sizeof(TByteInfo));

        ownerForm.regiontree.Add(p);

        result:=p;

      end
      else
        exit;
    end;

  finally
    ownerform.regiontreeMREW.Endwrite;
  end;
end;


procedure TUltimap2Worker.HandleIPForRegion(ip: qword; c: pt_insn_class; region: PRegionInfo);
var index: integer;
begin
  //do something with this IP
  index:=ip-region^.address;

  if (region^.info[index].flags=bifInvalidated) then exit;

  if (region^.info[index].count=0) then
  begin
    if ownerForm.allNewAreInvalid then
    begin
      region^.info[index].flags:=bifInvalidated;
      exit;
    end;

    region^.info[index].count:=1;
    region^.info[index].flags:=bifExecuted;

    if c in [ptic_call, ptic_far_call] then
      region^.info[index].flags:=region^.info[index].flags or bifIsCall;
  end
  else
  if region^.info[index].count<255 then
    inc(region^.info[index].count);
end;



procedure TUltimap2Worker.HandleIP(ip: QWORD; c: pt_insn_class);
var
  e: TRegionInfo;
  n: TAvgLvlTreeNode;
begin
  if (lastRegion<>nil) and ((ip>=lastRegion^.address) and (ip<lastRegion^.address+lastRegion^.size)) then
  begin
    HandleIPForRegion(ip,c, lastRegion);
    exit;
  end;

  lastregion:=nil;


  e.address:=ip;
  ownerform.regiontreeMREW.Beginread;
  n:=ownerform.regiontree.Find(@e);
  if n<>nil then
    lastRegion:=n.data;

  ownerform.regiontreeMREW.Endread;

  if lastregion=nil then
    lastregion:=addIPBlockToRegionTree(ip);

  if lastRegion<>nil then
    HandleIPForRegion(ip, c, lastRegion);
end;

function TUltimap2Worker.waitForData(timeout: dword; var e: TUltimap2DataEvent): boolean;
begin
  result:=false;
  if fromfile then
  begin
    //wait for the fileready event
    if processFile.WaitFor(timeout)=wrSignaled then
    begin
      ultimap2_lockfile(id);
      if fileexists(filename) then
      begin
        if fileexists(filename+'.processing') then   //'shouldn't' happen
          deletefile(filename+'.processing');

        renamefile(filename, filename+'.processing');
        ultimap2_releasefile(id);

        filemap:=TFileMapping.create(filename+'.processing');

        e.Address:=ptruint(filemap.fileContent);
        e.Size:=filemap.filesize;
        result:=true;
      end;
    end
  end
  else
  begin
    result:=ultimap2_waitForData(timeout, e);
  end;
end;

procedure TUltimap2Worker.continueFromData(e: TUltimap2DataEvent);
begin
  if fromfile then
  begin
    if filemap<>nil then
      freeandnil(filemap);



    done:=true;
  end
  else
    ultimap2_continue(e.Cpunr);
end;

procedure TUltimap2Worker.execute;
var
  e: TUltimap2DataEvent;

  iptConfig: pt_config;
  decoder: ppt_insn_decoder;
  callbackImage: PPT_Image;
  insn: pt_insn;
  i: integer;

begin
  callbackImage:=pt_image_alloc('xxx');
  pt_image_set_callback(callbackImage,@iptReadMemory,self);

  pt_config_init(@iptConfig);
  pt_cpu_read(@iptConfig.cpu);
  pt_cpu_errata(@iptConfig.errata, @iptConfig.cpu);

  while not terminated do
  begin

    if waitForData(250, e) then
    begin
      try
        //process the data between e.Address and e.Address+e.Size
        totalsize:=e.Size;
        iptConfig.beginaddress:=pointer(e.Address);
        iptConfig.endaddress:=pointer(e.Address+e.Size);

        decoder:=pt_insn_alloc_decoder(@iptConfig);
        if decoder<>nil then
        begin
          try
            pt_insn_set_image(decoder, callbackImage);

            //scan through this decoder

            i:=0;
            while (pt_insn_sync_forward(decoder)>=0) and (not terminated) do
            begin
              //percentagetotal

              while (pt_insn_next(decoder, @insn, sizeof(insn))>=0) and (not terminated) do
              begin
                if insn.iclass=ptic_error then break;

                handleIP(insn.ip, insn.iclass);

                inc(i);
                if i>512 then
                begin
                  pt_insn_get_offset(decoder, @processed);

                  i:=0;
                end;
              end;
            end;
          finally
            pt_insn_free_decoder(decoder);
          end;
        end;

      finally
        processed:=totalsize;
        done:=true;
        continueFromData(e);
      end;
    end else sleep(1);
  end;

  pt_image_free(callbackImage);
end;

destructor TUltimap2Worker.destroy;
begin
  Terminate;
  if processFile<>nil then
    processFile.SetEvent;

  waitfor;
  freeandnil(processFile);
  inherited destroy;
end;

constructor TUltimap2Worker.create(CreateSuspended: boolean);
begin
  inherited create(createsuspended);

  processFile:=TEvent.Create(nil,false,false,'');
end;


{TUltimap2FilterThread}

procedure TUltimap2FilterThread.EnableGUI;
begin
  ownerform.filterThread:=nil;
  ownerform.FilterGUI(true);

  if ExcludeFuturePaths and (not ownerform.cbfilterOutNewEntries.checked) then
    ownerform.cbfilterOutNewEntries.checked:=true;
end;

procedure TUltimap2FilterThread.execute;
begin
  freeOnTerminate:=true;

  //scan and check for terminated to see when it should terminate

  Synchronize(@EnableGUI);
end;

{ TfrmUltimap2 }

//RegionCompare

function TfrmUltimap2.RegionCompare(Tree: TAvgLvlTree; Data1, Data2: pointer): integer;
var
  d1,d2: PRegionInfo;
  start,stop: ptruint;
  a: ptruint;
begin
  d1:=data1;
  d2:=data2;
  {
  a:=d1^.address;
  start:=d2^.address;
  stop:=d2^.address+d2^.size;

  outputdebugstring(pchar(format('is %x in %x - %x', d1^.address, start,stop)); }

  if (d1^.address>=d2^.address) and (d1^.address<d2^.address+d2^.size) then
  begin
    result:=0
  end
  else
    result:=CompareValue(d2^.address, d1^.address); //not inside
end;


procedure TfrmUltimap2.freeRegion(r: PRegionInfo);
begin
  if r<>nil then
  begin
    if r^.info<>nil then
    begin
      freemem(r^.info);
      r^.info:=nil;
    end;

    if r^.memory<>nil then
    begin
      freemem(r^.memory);
      r^.memory:=nil;
    end;

    freemem(r);
  end;
end;

procedure TfrmUltimap2.FilterGUI(state: boolean);
begin
  btnReset.enabled:=state;
  btnNotExecuted.enabled:=state;
  btnExecuted.enabled:=state;
  cbFilterFuturePaths.enabled:=state;
  btnNotCalled.enabled:=state;
  btnFilterCallCount.enabled:=state;
  edtCallCount.enabled:=state;
  btnResetCount.enabled:=state;
  btnFilterModule.enabled:=state;
  cbfilterOutNewEntries.enabled:=state;
  btnCancelFilter.Visible:=not state;
end;

procedure TfrmUltimap2.setConfigGUIState(state: boolean);
begin
  lblBuffersPerCPU.enabled:=state;
  edtBufSize.enabled:=state;
  lblKB.enabled:=state;
  rbLogToFolder.enabled:=state;
  deTargetFolder.enabled:=state;
  rbRuntimeParsing.enabled:=state;

  gbRange.enabled:=state;
  lbRange.enabled:=state;
  btnAddRange.enabled:=state;
end;

procedure TfrmUltimap2.enableConfigGUI;
begin
  setConfigGUIState(true);
end;

procedure TfrmUltimap2.disableConfigGUI;
begin
  setConfigGUIState(false);
end;

procedure TfrmUltimap2.FlushResults(f: TFilterOption=foNone);
var i:integer;
begin
  ultimap2_flush;


  if rbLogToFolder.checked then
  begin
    //signal the worker threads to start processing
    if state=rsRecording then
    begin
      for i:=0 to length(workers)-1 do
      begin
        workers[i].totalsize:=0;
        workers[i].done:=false;
        workers[i].processFile.SetEvent;
      end;

      btnRecordPause.enabled:=false;
      tActivator.enabled:=true;
      //when the worker threads are all done, this will become enabled

      PostProcessingFilter:=f;
      state:=rsProcessing;

    end;
  end
  else
  begin

    //flush only returns after all data has been handled, so :
    if f<>foNone then
      Filter(f);
  end;
end;

procedure TfrmUltimap2.ExecuteFilter(Sender: TObject);
begin

end;

procedure TfrmUltimap2.setState(state: TRecordState);
begin
  fstate:=state;
  case state of
    rsRecording:
    begin
      label1.Caption:='Recording';
      panel1.color:=clRed;
    end;

    rsStopped:
    begin
      label1.Caption:='Paused';
      panel1.Color:=clGreen;
    end;

    rsProcessing:
    begin
      label1.Caption:='Processing'#13#10'Data';
      panel1.color:=$ff9900;
    end;
  end;
end;

procedure TfrmUltimap2.cleanup;
var i: integer;
begin
  //cleanup everything
  for i:=0 to length(workers)-1 do
    workers[i].Terminate;

  for i:=0 to length(workers)-1 do
  begin
    workers[i].Free;
    workers[i]:=nil;
  end;
  setlength(workers,0);

  if regiontree<>nil then
  begin
    while regiontree.root<>nil do
    begin
      freeRegion(PRegionInfo(regiontree.root.Data));
      regiontree.Delete(regiontree.root);
    end;

    regiontree.FreeAndClear;

    freeandnil(regiontree);
  end;






  enableConfigGUI;

  ultimap2_disable;
  ultimap2Initialized:=0;
end;

procedure TfrmUltimap2.tbRecordPauseChange(Sender: TObject);
var
  size: dword;
  ranges: TPRangeDynArray;
  r: TCPUIDResult;
  i: integer;

  regions: TMemoryRegions;

  p: PRegionInfo;
  br: ptruint;

  n: TAvgLvlTreeNode;
  e: TRegionInfo;
begin
  if state=rsProcessing then exit;

    if ((ultimap2Initialized=0) or (processid<>ultimap2Initialized)) then
    begin
      //first time init
      if ultimap2Initialized<>0 then
        cleanup;

      {ok, I know some of you AMD users will be wasting time removing this check
      and spending countless of hours trying to make this work, but trust me. It
      won't work. Your cpu doesn't have the required features

      Eric (db)
      }

      r:=CPUID(0);
      if (r.ebx<>1970169159) or (r.ecx<>1818588270) or (r.edx<>1231384169) then
        raise exception.create('Sorry, but Ultimap2 only works on Intel CPU''s');

      if (CPUID(7,0).ebx shr 25) and 1=0 then
        raise exception.create('Sorry, but your CPU seems to be lacking the Intel Processor Trace feature which Ultimap2 makes use of');

      if ((CPUID($14,0).ecx shr 1) and 1)=0 then
        raise exception.create('Sorry, but your CPU''s implementation of the Intel Processor Trace feature is too old. Ultimap uses multiple ToPA entries');

      if processid=0 then
        raise exception.create('First open a process');

      if processid=GetCurrentProcessId then
        raise exception.create('Target a different process. Ultimap2 will suspend the target when the buffer is full, and suspending the thing that empties the buffer is not a good idea');

      //initial checks are OK
      size:=strtoint(edtBufSize.text)*1024;
      if size<12*1024 then
        raise exception.create('The size has to be 12KB or higher');

      setlength(ranges,lbrange.count);
      for i:=0 to lbRange.Count-1 do
        if symhandler.ParseRange(lbRange.Items[i], ranges[i].startAddress, ranges[i].endaddress)=false then
          raise exception.create('For some weird reason "'+lbRange.Items[i]+'" can''t be parsed');

      //still here so everything seems alright.
      //turn off the config GUI
      disableConfigGUI;

      ultimap2Initialized:=processid;

      regiontree:=TAvgLvlTree.CreateObjectCompare(@RegionCompare);
      regiontreeMREW:=TMultiReadExclusiveWriteSynchronizer.Create;

      //launch worker threads
      setlength(workers, CPUCount);
      for i:=0 to length(workers)-1 do
      begin
        workers[i]:=TUltimap2Worker.Create(true);
        workers[i].id:=i;
        workers[i].fromFile:=rbLogToFolder.Checked;
        workers[i].Filename:=deTargetFolder.Directory;
        if workers[i].Filename<>'' then
        begin
          if workers[i].Filename[length(workers[i].Filename)]<>PathDelim then
            workers[i].Filename:=workers[i].Filename+PathDelim;

          workers[i].Filename:=workers[i].Filename+'CPU'+inttostr(i)+'.trace';
        end;
        workers[i].ownerForm:=self;
      end;



      if length(ranges)>0 then
      begin
        for i:=0 to length(ranges)-1 do
        begin
          getmem(p, sizeof(TRegionInfo));
          p^.address:=ranges[i].startAddress;
          p^.size:=ranges[i].endaddress-ranges[i].startAddress;
          getmem(p^.memory, p^.size);
          getmem(p^.info, size*sizeof(TByteInfo));
          ReadProcessMemory(processhandle, pointer(p^.address), p^.memory, p^.size, br);
          if br=0 then
            freeRegion(p)
          else
          begin
            p^.size:=br;
            zeromemory(p^.info, p^.size*sizeof(TByteInfo));
            regiontree.Add(p);
          end;
        end;
      end
      else
      begin
        getexecutablememoryregionsfromregion(0, qword($ffffffffffffffff), regions);
        for i:=0 to length(regions)-1 do
        begin
          getmem(p, sizeof(TRegionInfo));

          p^.address:=regions[i].BaseAddress;
          p^.size:=regions[i].MemorySize;
          getmem(p^.memory, p^.size);
          getmem(p^.info, p^.size*sizeof(TByteInfo));
          ReadProcessMemory(processhandle, pointer(p^.address), p^.memory, p^.size, br);
          if br=0 then
            freeRegion(p)
          else
          begin
            p^.size:=br;
            zeromemory(p^.info, p^.size*sizeof(TByteInfo));
            regiontree.Add(p);
          end;
        end;
      end;


      //start the recording


      if not libIptInit then raise exception.create('Failure loading libipt');


      if rbLogToFolder.Checked then
        ultimap2(processid, size, deTargetFolder.Directory, ranges)
      else
        ultimap2(processid, size, '', ranges);

      for i:=0 to length(workers)-1 do
        workers[i].start;

      state:=rsRecording;
    end
    else
    begin
      //toggle between active/disabled
      if state=rsStopped then
      begin
        ultimap2_resume;
        state:=rsRecording;
      end
      else
      if state=rsRecording then
      begin
        FlushResults(foNone);

        if rbRuntimeParsing.checked then
        begin
          ultimap2_pause;
          state:=rsStopped;
        end;
      end;
    end;

end;

procedure TfrmUltimap2.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  canclose:=MessageDlg('Closing will free all collected data. Continue? (Tip: You can minimize this window instead)', mtConfirmation,[mbyes,mbno], 0, mbno)=mryes;
end;

procedure TfrmUltimap2.FormCreate(Sender: TObject);
begin
  state:=rsStopped;
end;

function TfrmUltimap2.ModuleSelectEvent(index: integer; listText: string): string;
var
  mi: TModuleInfo;
  address: ptruint;
begin
  if (index<>-1) and (l<>nil) then
  begin
    address:=ptruint(l.Objects[index]);
    if symhandler.getmodulebyaddress(address, mi) then
      exit(inttohex(mi.baseaddress,8)+'-'+inttohex(mi.baseaddress+mi.basesize,8));
  end;

  result:=listText+' -error';
end;

procedure TfrmUltimap2.btnAddRangeClick(Sender: TObject);
var
  r: string;
  output: string;
  start, stop: uint64;
begin
  if l=nil then
    l:=tstringlist.create;

  symhandler.getModuleList(l);
  output:='';
  ShowSelectionList(self, 'Module list', 'Select a module or give your own range', l, output, true, @ModuleSelectEvent);
  if output<>'' then
  begin
    //check that output can be parsed

    if symhandler.parseRange(output, start, stop) then
      lbrange.Items.Add(inttohex(start,8)+'-'+inttohex(stop,8));
  end;

  freeandnil(l);
end;

procedure TfrmUltimap2.Filter(filterOption: TFilterOption);
begin
  if filterThread<>nil then
  begin
    OutputDebugString('Filter operation canceled. A filter operation was still going on');
    exit;
  end;

  OutputDebugString('going to launch a filter thread');

  //suspend gui
  FilterGUI(false);

  //launch the filter thread
  filterThread:=TUltimap2FilterThread.Create(true);
  filterthread.filterOption:=filterOption;
  filterthread.callcount:=Filtercount;
  filterthread.rangestart:=FilterRangeFrom;
  filterthread.rangestop:=FilterRangeTo;
  filterThread.ExcludeFuturePaths:=filterExcludeFuturePaths;
  filterthread.start;

  //the filter thread will reenable the gui when done and update the windowstate  (it also sets filterthread to nil in the mainthread)
end;

procedure TfrmUltimap2.btnExecutedClick(Sender: TObject);
begin
  flushResults(foNotExecuted); //filters out not executed memory
  filterExcludeFuturePaths:=cbFilterFuturePaths.checked;
end;

procedure TfrmUltimap2.btnFilterCallCountClick(Sender: TObject);
begin
  Filtercount:=strtoint(edtCallCount.text);
  flushResults(foExecuteCountLowerThan);
end;

procedure TfrmUltimap2.btnFilterModuleClick(Sender: TObject);
var
  r: string;
  output: string;
begin
  if l=nil then
    l:=tstringlist.create;

  symhandler.getModuleList(l);
  output:='';
  ShowSelectionList(self, 'Module list', 'Select a module or give your own range', l, output, true, @ModuleSelectEvent);
  if output<>'' then
  begin
    //check that output can be parsed
    if not symhandler.parseRange(output, FilterRangeFrom, FilterRangeTo) then
    begin
      MessageDlg(output+' is an invalid range', mtError, [mbok],0);
      exit;
    end;

  end;

  freeandnil(l);
  flushResults(foNotInRange);
end;

procedure TfrmUltimap2.btnNotCalledClick(Sender: TObject);
begin
  flushResults(foNonCALLInstructions);
end;

procedure TfrmUltimap2.btnNotExecutedClick(Sender: TObject);
begin
  flushResults(foExecuted); //filters out executed memory
end;

procedure TfrmUltimap2.btnCancelFilterClick(Sender: TObject);
begin
  if filterThread<>nil then
  begin
    filterThread.Terminate;
    btnCancelFilter.enabled:=false;
  end;
end;

procedure TfrmUltimap2.btnResetClick(Sender: TObject);
begin
  flushResults(foResetAll);
end;

procedure TfrmUltimap2.cbfilterOutNewEntriesChange(Sender: TObject);
begin
  allNewAreInvalid:=cbfilterOutNewEntries.checked;
end;

procedure TfrmUltimap2.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction:=caFree;
end;



procedure TfrmUltimap2.FormDestroy(Sender: TObject);
begin
  cleanup;
  frmUltimap2:=nil;
end;

procedure TfrmUltimap2.miRangeDeleteSelectedClick(Sender: TObject);
var i: integer;
begin
  for i:=lbrange.Items.Count-1 downto 0 do
    if lbrange.Selected[i] then
      lbRange.Items.Delete(i);
end;

procedure TfrmUltimap2.miRangeDeleteAllClick(Sender: TObject);
begin
  lbRange.clear;
end;

procedure TfrmUltimap2.Panel5Click(Sender: TObject);
begin

end;

procedure TfrmUltimap2.tActivatorTimer(Sender: TObject);
var
  done: boolean;
  i: integer;

  totalprocessed, totalsize: qword;
begin
  done:=true;
  totalprocessed:=0;
  totalsize:=0;
  for i:=0 to length(workers)-1 do
  begin
    if not workers[i].done then
      done:=false;

    if workers[i].totalsize<>0 then
    begin
      totalprocessed:=totalprocessed+workers[i].processed;
      totalsize:=totalsize+workers[i].totalsize;
    end
    else
      totalsize:=totalsize*2;
  end;

  if not done then
  begin
    if totalsize>0 then
      label1.Caption:='Processing'#13#10'Data'#13#10+format('%.2f', [(totalprocessed / totalsize) * 100])+'%'
    else
      label1.Caption:='Processing'#13#10'Data'#13#10'0%';

    exit;
  end;

  btnRecordPause.enabled:=true;
  tActivator.Enabled:=false;

  state:=rsStopped;

  if PostProcessingFilter<>foNone then
    Filter(PostPRocessingFilter);
end;



end.

