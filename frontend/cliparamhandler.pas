unit CliParamHandler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type

  TArgumentType = (atNone, atInt, atString);

  { TCliOption }

  TCliOption = class
    private
      fshortName: char;
      flongName: string;
      ftype: TArgumentType;
      fdescription: string;
      fvalue: string;
    public
      property ShortName: char read fshortName;
      property LongName: string read flongName;
      property ArgumentType: TArgumentType read ftype;
      property Description: string read fdescription;
      property Value: string read fvalue write fvalue;
      constructor Create(const shortName_: char; const argtype: TArgumentType; const longName_, desc: string);
  end;

  TOptionList = specialize TFPGList<TCliOption>;

  { TCliOptionHandler }

  TCliOptionHandler = class
    private
      options: TOptionList;
      setOptions: TOptionList;
      lastOption: TCliOption;
      unparsed: TStringList;
      function HasShortOption(const shortName: char): boolean;
    public
      constructor Create;
      destructor Destroy; override;
      procedure AddOption(const shortName: char; const arg: TArgumentType; const longName, desc: string);
      procedure ParseParameters;
      function IsSet(const longOptName: string): boolean;
      function GetOptionValue(const longOptName: string): string;
      function GetShortOptionValue(const shortName: char): string;
      function UnparsedCount: integer;
      function GetUnparsedParams: TStringList;
      function GetUnparsed(const index: word): string;
      function GetDescriptions: String;
      procedure PrintSetOpts;
    public
      property OptionValue[shortName: char]: string read GetShortOptionValue; default;
  end;

implementation

function ArgTypeToString(const arg: TArgumentType): string;
begin
  result := '';
  case arg of
      atString: result := '<string>';
      atInt:    result := '<int>';
  end;
end;

{ TCliParameter }

constructor TCliOption.Create(const shortName_: char; const argtype: TArgumentType; const longName_, desc: string);
begin
  fshortName := shortName_;
  flongName := longName_;
  ftype := argtype;
  fdescription := desc;
  value := '';
end;

{ TCliOptionHandler }

constructor TCliOptionHandler.Create;
begin
  options := TOptionList.Create;
  setOptions := TOptionList.Create;
  lastOption := nil;
  unparsed := TStringList.Create;
end;

destructor TCliOptionHandler.Destroy;
var
  option: TCliOption;
begin
  for option in options do
      option.Free;
  options.Free;
  setOptions.Free;
  unparsed.Free;
end;

procedure TCliOptionHandler.AddOption(const shortName: char; const arg: TArgumentType; const longName, desc: string);
var
  option: TCliOption;
begin
  option := TCliOption.Create(shortName, arg, longName, desc);
  options.Add(option);
end;

procedure TCliOptionHandler.ParseParameters;
var
  i: integer;
  optStr: string;
  option: TCliOption;
  parsed: boolean;

  procedure TestArgument;
  begin
    if option.ArgumentType <> atNone then begin
        if i <= Paramcount - 1 then
            option.Value := ParamStr(i + 1)
        else
            raise EParserError.Create('Missing parameter for option: ' + option.LongName);
        i += 1;
    end;
  end;

begin
  i := 1;
  while i <= Paramcount do begin
      optStr := ParamStr(i);
      parsed := false;
      for option in options do begin
          //try shortopt
          if (length(optStr) = 2) and (optStr[1] = '-') then begin
              if optStr[2] = option.ShortName then begin
                  setOptions.Add(option);
                  TestArgument;
                  parsed := true;
              end;
          end;
          //try longOpt
          if (length(optStr) > 2) then begin
              if optStr = '--' + option.LongName then begin
                  setOptions.Add(option);
                  TestArgument;
                  parsed := true;
              end;
          end;
      end;
      if not parsed then
          unparsed.Add(optStr);
      i += 1;
  end;
end;

function TCliOptionHandler.IsSet(const longOptName: string): boolean;
var
  option: TCliOption;
begin
  result := false;
  Assert(Length(longOptName) > 1, 'LongOpt must have two chars at least!');
  for option in setOptions do begin
      if option.LongName = longOptName then begin
          result := true;
          lastOption := option;
          //exit; //exit or break causes crashes when assembled with yasm
      end;
  end;
end;

function TCliOptionHandler.HasShortOption(const shortName: char): boolean;
var
  option: TCliOption;
begin
  for option in setOptions do
      if option.ShortName = shortName then begin
          result := true;
          lastOption := option;
          exit;
      end;
  result := false;
end;

function TCliOptionHandler.GetOptionValue(const longOptName: string): string;
begin
  if (lastOption <> nil) and (longOptName = lastOption.LongName) then
      result := lastOption.Value
  else begin
      if not IsSet(longOptName) then
          raise EParserError.Create(longOptName + ': parameter was not set')
      else
          result := lastOption.Value;
  end;
end;

function TCliOptionHandler.GetShortOptionValue(const shortName: char): string;
begin
  if (lastOption <> nil) and (shortName = lastOption.ShortName) then
      result := lastOption.Value
  else begin
      if not HasShortOption(shortName) then
          raise EParserError.Create(shortName + ': parameter was not set')
      else
          result := lastOption.Value;
      writeln(result);
  end;
end;

function TCliOptionHandler.UnparsedCount: integer;
begin
  result := unparsed.Count;
end;

function TCliOptionHandler.GetUnparsedParams: TStringList;
begin
  result := unparsed;
end;

function TCliOptionHandler.GetUnparsed(const index: word): string;
begin
  if index >= unparsed.Count then
      raise EParserError.Create('no unparsed option with index: ' + IntToStr(index));
  result := unparsed.Strings[index];
end;

function TCliOptionHandler.GetDescriptions: String;
var
  option: TCliOption;
  left: string;
begin
  result := '';
  for option in options do begin
      left := format('  -%s, --%s %s', [option.ShortName, option.LongName, ArgTypeToString(option.ArgumentType)]);
      result += format('%-28s ', [left]) + option.Description + LineEnding;
  end;
end;

procedure TCliOptionHandler.PrintSetOpts;
var
  option: TCliOption;
begin
  for option in setOptions do begin
      writeln(option.LongName + ': ' + option.Value);
  end;
end;

end.

