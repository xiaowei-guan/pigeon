// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/functional.dart';

import 'ast.dart';
import 'generator_tools.dart';

/// Options that control how C++ code will be generated.
class CppOptions {
  /// Creates a [CppOptions] object
  const CppOptions({
    this.header,
    this.namespace,
    this.copyrightHeader,
  });

  /// The path to the header that will get placed in the source filed (example:
  /// "foo.h").
  final String? header;

  /// The namespace where the generated class will live.
  final String? namespace;

  /// A copyright header that will get prepended to generated code.
  final Iterable<String>? copyrightHeader;

  /// Creates a [CppOptions] from a Map representation where:
  /// `x = CppOptions.fromMap(x.toMap())`.
  static CppOptions fromMap(Map<String, Object> map) {
    return CppOptions(
      header: map['header'] as String?,
      namespace: map['namespace'] as String?,
      copyrightHeader: map['copyrightHeader'] as Iterable<String>?,
    );
  }

  /// Converts a [CppOptions] to a Map representation where:
  /// `x = CppOptions.fromMap(x.toMap())`.
  Map<String, Object> toMap() {
    final Map<String, Object> result = <String, Object>{
      if (header != null) 'header': header!,
      if (namespace != null) 'namespace': namespace!,
      if (copyrightHeader != null) 'copyrightHeader': copyrightHeader!,
    };
    return result;
  }

  /// Overrides any non-null parameters from [options] into this to make a new
  /// [CppOptions].
  CppOptions merge(CppOptions options) {
    return CppOptions.fromMap(mergeMaps(toMap(), options.toMap()));
  }
}

String _getCodecName(Api api) => '${api.name}CodecSerializer';

String _pointerPrefix = 'pointer';
String _encodablePrefix = 'encodable';

void _writeCodecHeader(Indent indent, Api api, Root root) {
  final String codecName = _getCodecName(api);
  indent.write('class $codecName : public flutter::StandardCodecSerializer ');
  indent.scoped('{', '};', () {
    indent.scoped(' public:', '', () {
      indent.writeln('');
      indent.format('''
inline static $codecName& GetInstance() {
\tstatic $codecName sInstance;
\treturn sInstance;
}
''');
      indent.writeln('$codecName();');
    });
    if (getCodecClasses(api, root).isNotEmpty) {
      indent.writeScoped(' public:', '', () {
        indent.writeln(
            'void WriteValue(const flutter::EncodableValue& value, flutter::ByteStreamWriter* stream) const;');
      });
      indent.writeScoped(' protected:', '', () {
        indent.writeln(
            'flutter::EncodableValue ReadValueOfType(uint8_t type, flutter::ByteStreamReader* stream) const;');
      });
    }
  }, nestCount: 0);
}

void _writeCodecSource(Indent indent, Api api, Root root) {
  final String codecName = _getCodecName(api);
  indent.writeln('$codecName::$codecName() {}');
  if (getCodecClasses(api, root).isNotEmpty) {
    indent.write(
        'flutter::EncodableValue $codecName::ReadValueOfType(uint8_t type, flutter::ByteStreamReader* stream) const');
    indent.scoped('{', '}', () {
      indent.write('switch (type) ');
      indent.scoped('{', '}', () {
        for (final EnumeratedClass customClass in getCodecClasses(api, root)) {
          indent.write('case ${customClass.enumeration}: ');
          indent.writeScoped('', '', () {
            indent.writeln(
                'return flutter::CustomEncodableValue(${customClass.name}(std::get<flutter::EncodableMap>(ReadValue(stream))));');
          });
        }
        indent.write('default:');
        indent.writeScoped('', '', () {
          indent.writeln(
              'return flutter::StandardCodecSerializer::ReadValueOfType(type, stream);');
        });
      });
    });
    indent.writeln('');
    indent.write(
        'void $codecName::WriteValue(const flutter::EncodableValue& value, flutter::ByteStreamWriter* stream) const');
    indent.writeScoped('{', '}', () {
      indent.write(
          'if (const flutter::CustomEncodableValue* custom_value = std::get_if<flutter::CustomEncodableValue>(&value))');
      indent.scoped('{', '}', () {
        for (final EnumeratedClass customClass in getCodecClasses(api, root)) {
          indent.write(
              'if (custom_value->type() == typeid(${customClass.name}))');
          indent.scoped('{', '}', () {
            indent.writeln('stream->WriteByte(${customClass.enumeration});');
            indent.writeln(
                'WriteValue(std::any_cast<${customClass.name}>(*custom_value).ToEncodableMap(), stream);');
            indent.writeln('return;');
          });
        }
      });
      indent.writeln(
          'flutter::StandardCodecSerializer::WriteValue(value, stream);');
    });
  }
}

void _writeException(Indent indent) {
  indent.format('''
class FlutterException : public std::exception {
 public:
 \tFlutterException(std::string message) : message_(message){};
 \tconst char* what() const throw() { return message_.c_str(); }

 private:
 \tstd::string message_;
};
''');
}

void _writeErrorOr(Indent indent) {
  indent.format('''
class FlutterError {
 public:
\tFlutterError();
\tFlutterError(std::string arg_code)
\t\t: code(arg_code) {};
\tFlutterError(std::string arg_code, std::string arg_message)
\t\t: code(arg_code), message(arg_message) {};
\tFlutterError(std::string arg_code, std::string arg_message, std::string arg_details)
\t\t: code(arg_code), message(arg_message), details(arg_details) {};
\tstd::string code;
\tstd::string message;
\tstd::string details;
};
template<class T> class ErrorOr {
\tstd::variant<T, FlutterError> v;
\tbool ok = true;
 public:
\tErrorOr() { new(&v) T(); }
\tErrorOr(const T& rhs) { new(&v) T(rhs); }
\tErrorOr(const FlutterError& rhs) : ok(false) {
\t\tnew(&v) FlutterError(rhs);
\t}
\tbool hasError() const { return !ok; }
\tconst T& value() const { return std::get<T>(v); };
\tconst FlutterError& error() const { return std::get<FlutterError>(v); };
};
''');
}

void _writeHostApiHeader(Indent indent, Api api) {
  assert(api.location == ApiLocation.host);

  indent.writeln(
      '/* Generated class from Pigeon that represents a handler of messages from Flutter. */');
  indent.write('class ${api.name} ');
  indent.scoped('{', '};', () {
    indent.scoped(' public:', '', () {
      indent.writeln('${api.name}(const ${api.name}&) = delete;');
      indent.writeln('${api.name}& operator=(const ${api.name}&) = delete;');
      indent.writeln('virtual ~${api.name}() { };');
      for (final Method method in api.methods) {
        final String returnTypeName = method.returnType.isVoid
            ? 'std::optional<FlutterError>'
            : 'ErrorOr<${_cppTypeForDartType(method.returnType)}>';
        final List<String> argSignature = <String>[];
        if (method.arguments.isNotEmpty) {
          final Iterable<String> argTypes = method.arguments
              .map((NamedType e) => _nullsafeCppTypeForDartType(e.type));
          final Iterable<String> argNames =
              method.arguments.map((NamedType e) => e.name);
          argSignature.addAll(
              map2(argTypes, argNames, (String argType, String argName) {
            return '$argType $argName';
          }));
        }
        if (method.isAsynchronous) {
          argSignature.add('std::function<void($returnTypeName reply)> result');
          indent.writeln(
              'virtual void ${method.name}(${argSignature.join(', ')}) = 0;');
        } else {
          indent.writeln(
              'virtual $returnTypeName ${method.name}(${argSignature.join(', ')}) = 0;');
        }
      }
      indent.addln('');
      indent.writeln('/** The codec used by ${api.name}. */');
      indent.writeln('static const flutter::StandardMessageCodec& GetCodec();');
      indent.writeln(
          '/** Sets up an instance of `${api.name}` to handle messages through the `binary_messenger`. */');
      indent.writeln(
          'static void SetUp(flutter::BinaryMessenger* binary_messenger, ${api.name}* api);');
      indent.writeln(
          'static flutter::EncodableMap WrapError(const std::exception& exception);');
      indent.writeln(
          'static flutter::EncodableMap WrapError(const FlutterError& error);');
    });
    indent.scoped(' protected:', '', () {
      indent.writeln('${api.name}() = default;');
    });
  }, nestCount: 0);
}

void _writeHostApiSource(Indent indent, Api api) {
  assert(api.location == ApiLocation.host);
/*
  final String codecName = _getCodecName(api);
  indent.format('''
/** The codec used by ${api.name}. */
const flutter::StandardMessageCodec& ${api.name}::GetCodec() {
\treturn flutter::StandardMessageCodec::GetInstance(&$codecName::GetInstance());
}
''');
*/
  indent.writeln(
      '/** Sets up an instance of `${api.name}` to handle messages through the `binary_messenger`. */');
  indent.write(
      'void ${api.name}::SetUp(flutter::BinaryMessenger* binary_messenger, ${api.name}* api) ');
  indent.scoped('{', '}', () {
    for (final Method method in api.methods) {
      final String channelName = makeChannelName(api, method);
      indent.write('');
      indent.scoped('{', '}', () {
        indent.writeln(
            'auto channel = std::make_unique<flutter::BasicMessageChannel<flutter::EncodableValue>>(');
        indent.inc();
        indent.inc();
        indent.writeln(
            'binary_messenger, "$channelName", &flutter::StandardMessageCodec::GetInstance());');
        indent.dec();
        indent.dec();
        indent.write('if (api != nullptr) ');
        indent.scoped('{', '} else {', () {
          indent.write(
              'channel->SetMessageHandler([api](const flutter::EncodableValue& message, const flutter::MessageReply<flutter::EncodableValue>& reply)');
          indent.scoped('{', '});', () {
            final String returnTypeName = method.returnType.isVoid
                ? 'std::optional<FlutterError>'
                : 'ErrorOr<${_cppTypeForDartType(method.returnType)}>';
            indent.writeln('flutter::EncodableMap wrapped;');
            indent.write('try ');
            indent.scoped('{', '}', () {
              final List<String> methodArgument = <String>[];
              if (method.arguments.isNotEmpty) {
                indent.writeln(
                    'auto args = std::get<flutter::EncodableList>(message);');
                enumerate(method.arguments, (int index, NamedType arg) {
                  final String argType = _nullsafeCppTypeForDartType(arg.type);
                  final String argName = _getSafeArgumentName(index, arg);

                  final String encodableArgName =
                      '${_encodablePrefix}_$argName';
                  indent.writeln('auto $encodableArgName = args.at($index);');
                  if (!arg.type.isNullable) {
                    indent.write('if ($encodableArgName.IsNull()) ');
                    indent.scoped('{', '}', () {
                      indent.writeln(
                          'throw FlutterException("$argName unexpectedly null.");');
                    });
                  }
                  indent.writeln(
                      '$argType $argName = std::any_cast<$argType>(std::get<flutter::CustomEncodableValue>($encodableArgName));');
                  methodArgument.add(argName);
                });
              }

              String _wrapResponse(String reply, bool isVoid) {
                final String result;
                final String ifCondition;
                final String errorGetter;
                if (isVoid) {
                  result = 'flutter::EncodableValue()';
                  ifCondition = 'output.has_value()';
                  errorGetter = 'value';
                } else {
                  result = 'flutter::CustomEncodableValue(output.value())';
                  ifCondition = 'output.hasError()';
                  errorGetter = 'error';
                }
                return '\tif ($ifCondition) {${indent.newline}'
                    '\t\twrapped.insert(std::make_pair(flutter::EncodableValue("${Keys.error}"), WrapError(output.$errorGetter())));${indent.newline}'
                    '$reply'
                    '\t} else {${indent.newline}'
                    '\t\twrapped.insert(std::make_pair(flutter::EncodableValue("${Keys.result}"), $result));${indent.newline}'
                    '$reply'
                    '\t}';
              }

              if (method.isAsynchronous) {
                methodArgument.add(
                  '[&wrapped, &reply]($returnTypeName output) { ${indent.newline}'
                  '${_wrapResponse('\t\treply(flutter::EncodableValue(wrapped)); ${indent.newline}', method.returnType.isVoid)}'
                  '}',
                );
              }
              final String call =
                  'api->${method.name}(${methodArgument.join(', ')})';
              if (method.isAsynchronous) {
                indent.format('$call;');
              } else {
                indent.writeln('$returnTypeName output = $call;');
                indent.format(_wrapResponse('', method.returnType.isVoid));
              }
            });
            indent.write('catch (const std::exception& exception) ');
            indent.scoped('{', '}', () {
              indent.writeln(
                  'wrapped.insert(std::make_pair(flutter::EncodableValue("${Keys.error}"), WrapError(exception)));');
              if (method.isAsynchronous) {
                indent.writeln('reply(flutter::EncodableValue(wrapped));');
              }
            });
            if (!method.isAsynchronous) {
              indent.writeln('reply(flutter::EncodableValue(wrapped));');
            }
          });
        });
        indent.scoped(null, '}', () {
          indent.writeln('channel->SetMessageHandler(nullptr);');
        });
      });
    }
  });
}

String _getArgumentName(int count, NamedType argument) =>
    argument.name.isEmpty ? 'arg$count' : argument.name;

/// Returns an argument name that can be used in a context where it is possible to collide.
String _getSafeArgumentName(int count, NamedType argument) =>
    _getArgumentName(count, argument) + '_arg';

void _writeFlutterApiHeader(Indent indent, Api api) {
  assert(api.location == ApiLocation.flutter);
  indent.writeln(
      '/* Generated class from Pigeon that represents Flutter messages that can be called from C++. */');
  indent.write('class ${api.name} ');
  indent.scoped('{', '};', () {
    indent.scoped(' private:', '', () {
      indent.writeln('flutter::BinaryMessenger* binary_messenger_;');
    });
    indent.scoped(' public:', '', () {
      indent.write('${api.name}(flutter::BinaryMessenger* binary_messenger);');
      indent.writeln('');
      indent.writeln('static const flutter::StandardMessageCodec& GetCodec();');
      for (final Method func in api.methods) {
        final String returnType = func.returnType.isVoid
            ? 'void'
            : _nullsafeCppTypeForDartType(func.returnType);
        if (func.arguments.isEmpty) {
          indent.writeln(
              'void ${func.name}(std::function<void($returnType)>&& callback);');
        } else {
          final Iterable<String> argTypes = func.arguments
              .map((NamedType e) => _nullsafeCppTypeForDartType(e.type));
          final Iterable<String> argNames =
              indexMap(func.arguments, _getSafeArgumentName);
          final String argsSignature =
              map2(argTypes, argNames, (String x, String y) => '$x $y')
                  .join(', ');
          indent.writeln(
              'void ${func.name}($argsSignature, std::function<void($returnType)>&& callback);');
        }
      }
    });
  }, nestCount: 0);
}

void _writeFlutterApiSource(Indent indent, Api api) {
  assert(api.location == ApiLocation.flutter);
  indent.writeln(
      '/* Generated class from Pigeon that represents Flutter messages that can be called from C++. */');
  indent.write(
      '${api.name}::${api.name}(flutter::BinaryMessenger* binary_messenger)');
  indent.scoped('{', '}', () {
    indent.writeln('this->binary_messenger_ = binary_messenger;');
  });
  indent.writeln('');
/*
  final String codecName = _getCodecName(api);
  indent.format('''
const flutter::StandardMessageCodec& ${api.name}::GetCodec() {
\treturn flutter::StandardMessageCodec::GetInstance(&$codecName::GetInstance());
}
''');
*/
  for (final Method func in api.methods) {
    final String channelName = makeChannelName(api, func);
    final String returnType = func.returnType.isVoid
        ? 'void'
        : _nullsafeCppTypeForDartType(func.returnType);
    String sendArgument;
    if (func.arguments.isEmpty) {
      indent.write(
          'void ${api.name}::${func.name}(std::function<void($returnType)>&& callback) ');
      sendArgument = 'flutter::EncodableValue()';
    } else {
      final Iterable<String> argTypes = func.arguments
          .map((NamedType e) => _nullsafeCppTypeForDartType(e.type));
      final Iterable<String> argNames =
          indexMap(func.arguments, _getSafeArgumentName);
      sendArgument =
          'flutter::EncodableList { ${(argNames.map((String arg) => 'flutter::CustomEncodableValue($arg)')).join(', ')} }';
      final String argsSignature =
          map2(argTypes, argNames, (String x, String y) => '$x $y').join(', ');
      indent.write(
          'void ${api.name}::${func.name}($argsSignature, std::function<void($returnType)>&& callback) ');
    }
    indent.scoped('{', '}', () {
      const String channel = 'channel';
      indent.writeln(
          'auto channel = std::make_unique<flutter::BasicMessageChannel<flutter::EncodableValue>>(');
      indent.inc();
      indent.inc();
      indent.writeln(
          'binary_messenger_, "$channelName", &flutter::StandardMessageCodec::GetInstance());');
      indent.dec();
      indent.dec();
      indent.write(
          '$channel->Send($sendArgument, [callback](const uint8_t* reply, size_t reply_size)');
      indent.scoped('{', '});', () {
        if (func.returnType.isVoid) {
          indent.writeln('callback();');
        } else {
          indent.writeln(
              'std::unique_ptr<flutter::EncodableValue> decoded_reply = GetCodec().DecodeMessage(reply, reply_size);');
          indent.writeln(
              'flutter::EncodableValue args = *(flutter::EncodableValue*)(decoded_reply.release());');
          const String output = 'output';

          final bool isBuiltin =
              _cppTypeForBuiltinDartType(func.returnType) != null;
          final String returnTypeName = _cppTypeForDartType(func.returnType);
          if (func.returnType.isNullable) {
            indent.writeln('$returnType $output{};');
          } else {
            indent.writeln('$returnTypeName $output{};');
          }
          final String pointerVariable = '${_pointerPrefix}_$output';
          if (func.returnType.baseName == 'int') {
            indent.format('''
if (const int32_t* $pointerVariable = std::get_if<int32_t>(&args))
\t$output = *$pointerVariable;
else if (const int64_t* ${pointerVariable}_64 = std::get_if<int64_t>(&args))
\t$output = *${pointerVariable}_64;''');
          } else if (!isBuiltin) {
            indent.write(
                'if (const flutter::EncodableMap* $pointerVariable = std::get_if<flutter::EncodableMap>(&args))');
            indent.scoped('{', '}', () {
              indent.writeln('$output = $returnTypeName(*$pointerVariable);');
            });
          } else {
            if (func.returnType.isNullable) {
              indent.writeln('$output = std::get_if<$returnTypeName>(&args);');
            } else {
              indent.write(
                  'if (const $returnTypeName* $pointerVariable = std::get_if<$returnTypeName>(&args))');
              indent.scoped('{', '}', () {
                indent.writeln('$output = *$pointerVariable;');
              });
            }
          }

          indent.writeln('callback($output);');
        }
      });
    });
  }
}

String _makeGetter(NamedType field) {
  final String uppercased =
      field.name.substring(0, 1).toUpperCase() + field.name.substring(1);
  return 'get$uppercased';
}

String _makeSetter(NamedType field) {
  final String uppercased =
      field.name.substring(0, 1).toUpperCase() + field.name.substring(1);
  return 'set$uppercased';
}

String? _cppTypeForBuiltinDartType(TypeDeclaration type) {
  const Map<String, String> cppTypeForDartTypeMap = <String, String>{
    'bool': 'bool',
    'int': 'int64_t',
    'String': 'std::string',
    'double': 'double',
    'Uint8List': 'std::vector<uint8_t>',
    'Int32List': 'std::vector<int32_t>',
    'Int64List': 'std::vector<int64_t>',
    'Float64List': 'std::vector<double>',
    'Map': 'flutter::EncodableMap',
    'List': 'flutter::EncodableList',
  };
  if (cppTypeForDartTypeMap.containsKey(type.baseName)) {
    return cppTypeForDartTypeMap[type.baseName];
  } else {
    return null;
  }
}

String _cppTypeForDartType(TypeDeclaration type) {
  return _cppTypeForBuiltinDartType(type) ?? type.baseName;
}

String _nullsafeCppTypeForDartType(TypeDeclaration type) {
  final String typeName = _cppTypeForDartType(type);
  if (type.isNullable) {
    return 'std::optional<$typeName>';
  } else {
    return 'const $typeName&';
  }
}

String _getGuardName(String? headerFileName, String? namespace) {
  String guardName = 'PIGEON_';
  if (headerFileName != null) {
    guardName += '${headerFileName.replaceAll('.', '_').toUpperCase()}_';
  }
  if (namespace != null) {
    guardName += '${namespace.toUpperCase()}_';
  }
  return guardName + 'H_';
}

/// Generates the ".h" file for the AST represented by [root] to [sink] with the
/// provided [options] and [headerFileName].
void generateCppHeader(
    String? headerFileName, CppOptions options, Root root, StringSink sink) {
  final Indent indent = Indent(sink);
  if (options.copyrightHeader != null) {
    addLines(indent, options.copyrightHeader!, linePrefix: '// ');
  }
  indent.writeln('// $generatedCodeWarning');
  indent.writeln('// $seeAlsoWarning');
  indent.addln('');
  final String guardName = _getGuardName(headerFileName, options.namespace);
  indent.writeln('#ifndef $guardName');
  indent.writeln('#define $guardName');
  indent.writeln('#include <flutter/encodable_value.h>');
  indent.writeln('#include <flutter/basic_message_channel.h>');
  indent.writeln('#include <flutter/binary_messenger.h>');
  indent.writeln('#include <flutter/standard_message_codec.h>');
  indent.addln('');
  indent.writeln('#include <map>');
  indent.writeln('#include <string>');
  indent.writeln('#include <optional>');

  indent.addln('');

  if (options.namespace != null) {
    indent.writeln('namespace ${options.namespace} {');
  }

  indent.addln('');
  indent.writeln('/* Generated class from Pigeon. */');

  for (final Enum anEnum in root.enums) {
    indent.writeln('');
    indent.write('enum class ${anEnum.name} ');
    indent.scoped('{', '};', () {
      int index = 0;
      for (final String member in anEnum.members) {
        indent.writeln(
            '$member = $index${index == anEnum.members.length - 1 ? '' : ','}');
        index++;
      }
    });
  }

  indent.addln('');

  _writeErrorOr(indent);
  indent.addln('');
  _writeException(indent);

  for (final Class klass in root.classes) {
    indent.addln('');
    indent.writeln(
        '/* Generated class from Pigeon that represents data sent in messages. */');
    indent.write('class ${klass.name} ');
    indent.scoped('{', '};', () {
      indent.scoped(' public:', '', () {
        indent.writeln('${klass.name}();');
        for (final NamedType field in klass.fields) {
          final HostDatatype hostDatatype = getHostDatatype(field, root.classes,
              root.enums, (NamedType x) => _cppTypeForBuiltinDartType(x.type));
          indent.writeln(
              '${hostDatatype.datatype} ${_makeGetter(field)}() const;');
          indent.writeln(
              'void ${_makeSetter(field)}(${hostDatatype.datatype} setterArg);');
          indent.addln('');
        }
      });

      indent.scoped(' private:', '', () {
        indent.writeln('${klass.name}(flutter::EncodableMap map);');
        indent.writeln('flutter::EncodableMap ToEncodableMap();');
        for (final Class friend in root.classes) {
          if (friend != klass &&
              friend.fields.any(
                  (NamedType element) => element.type.baseName == klass.name)) {
            indent.writeln('friend class ${friend.name};');
          }
        }
        for (final Api api in root.apis) {
          // TODO(gaaclarke): Find a way to be more precise with our
          // friendships.
          indent.writeln('friend class ${api.name};');
          indent.writeln('friend class ${_getCodecName(api)};');
        }

        for (final NamedType field in klass.fields) {
          final HostDatatype hostDatatype = getHostDatatype(field, root.classes,
              root.enums, (NamedType x) => _cppTypeForBuiltinDartType(x.type));
          indent.writeln('${hostDatatype.datatype} ${field.name}_;');
        }
      });
    }, nestCount: 0);
    indent.writeln('');
  }

  for (final Api api in root.apis) {
    //_writeCodecHeader(indent, api, root);
    indent.addln('');
    if (api.location == ApiLocation.host) {
      _writeHostApiHeader(indent, api);
    } else if (api.location == ApiLocation.flutter) {
      _writeFlutterApiHeader(indent, api);
    }
  }

  if (options.namespace != null) {
    indent.writeln('} // namespace');
  }

  indent.writeln('#endif  // $guardName');
}

/// Generates the ".cpp" file for the AST represented by [root] to [sink] with the
/// provided [options].
void generateCppSource(CppOptions options, Root root, StringSink sink) {
  final Set<String> rootClassNameSet =
      root.classes.map((Class x) => x.name).toSet();
  final Set<String> rootEnumNameSet =
      root.enums.map((Enum x) => x.name).toSet();
  final Indent indent = Indent(sink);
  if (options.copyrightHeader != null) {
    addLines(indent, options.copyrightHeader!, linePrefix: '// ');
  }
  indent.writeln('// $generatedCodeWarning');
  indent.writeln('// $seeAlsoWarning');
  indent.addln('');
  indent.addln('#undef _HAS_EXCEPTIONS');
  indent.addln('');
  indent.writeln('#include <flutter/basic_message_channel.h>');
  indent.writeln('#include <flutter/binary_messenger.h>');
  indent.writeln('#include <flutter/standard_message_codec.h>');
  indent.writeln('#include <map>');
  indent.writeln('#include <string>');
  indent.writeln('#include <optional>');

  indent.writeln('#include "${options.header}"');

  indent.addln('');

  indent.addln('');

  if (options.namespace != null) {
    indent.writeln('namespace ${options.namespace} {');
  }

  indent.addln('');
  indent.writeln('/* Generated class from Pigeon. */');

  for (final Class klass in root.classes) {
    indent.addln('');
    indent.writeln('/* ${klass.name} */');
    indent.addln('');
    for (final NamedType field in klass.fields) {
      final HostDatatype hostDatatype = getHostDatatype(field, root.classes,
          root.enums, (NamedType x) => _cppTypeForBuiltinDartType(x.type));
      indent.writeln(
          '${hostDatatype.datatype} ${klass.name}::${_makeGetter(field)}() const { return ${field.name}_; }');
      indent.writeln(
          'void ${klass.name}::${_makeSetter(field)}(${hostDatatype.datatype} setterArg) { this->${field.name}_ = setterArg; }');
      indent.addln('');
    }
    indent.write('flutter::EncodableMap ${klass.name}::ToEncodableMap() ');
    indent.scoped('{', '}', () {
      indent.writeln('flutter::EncodableMap toMapResult;');
      for (final NamedType field in klass.fields) {
        final HostDatatype hostDatatype = getHostDatatype(field, root.classes,
            root.enums, (NamedType x) => _cppTypeForBuiltinDartType(x.type));
        String toWriteValue = '';
        if (!hostDatatype.isBuiltin &&
            rootClassNameSet.contains(field.type.baseName)) {
          toWriteValue = '${field.name}_.ToEncodableMap()';
        } else if (!hostDatatype.isBuiltin &&
            rootEnumNameSet.contains(field.type.baseName)) {
          toWriteValue = 'flutter::EncodableValue((int)${field.name}_)';
        } else {
          toWriteValue = 'flutter::EncodableValue(${field.name}_)';
        }
        indent.writeln(
            'toMapResult.insert(std::make_pair(flutter::EncodableValue("${field.name}"), $toWriteValue));');
      }
      indent.writeln('return toMapResult;');
    });
    indent.writeln('${klass.name}::${klass.name}() {}');
    indent.write('${klass.name}::${klass.name}(flutter::EncodableMap map) ');
    indent.scoped('{', '}', () {
      for (final NamedType field in klass.fields) {
        final String pointerFieldName = '${_pointerPrefix}_${field.name}';
        final String encodableFieldName = '${_encodablePrefix}_${field.name}';
        indent.writeln(
            'auto $encodableFieldName = map.at(flutter::EncodableValue("${field.name}"));');
        if (rootEnumNameSet.contains(field.type.baseName)) {
          indent.writeln(
              'if (const int32_t* $pointerFieldName = std::get_if<int32_t>(&$encodableFieldName))\t${field.name}_ = (${field.type.baseName})*$pointerFieldName;');
        } else {
          final HostDatatype hostDatatype = getHostDatatype(field, root.classes,
              root.enums, (NamedType x) => _cppTypeForBuiltinDartType(x.type));
          if (field.type.baseName == 'int') {
            indent.format('''
if (const int32_t* $pointerFieldName = std::get_if<int32_t>(&$encodableFieldName))
\t${field.name}_ = *$pointerFieldName;
else if (const int64_t* ${pointerFieldName}_64 = std::get_if<int64_t>(&$encodableFieldName))
\t${field.name}_ = *${pointerFieldName}_64;''');
          } else if (!hostDatatype.isBuiltin &&
              root.classes
                  .map((Class x) => x.name)
                  .contains(field.type.baseName)) {
            indent.write(
                'if (const flutter::EncodableMap* $pointerFieldName = std::get_if<flutter::EncodableMap>(&$encodableFieldName))');
            indent.scoped('{', '}', () {
              indent.writeln(
                  '${field.name}_ = ${hostDatatype.datatype}(*$pointerFieldName);');
            });
          } else {
            indent.write(
                'if (const ${hostDatatype.datatype}* $pointerFieldName = std::get_if<${hostDatatype.datatype}>(&$encodableFieldName))');
            indent.scoped('{', '}', () {
              indent.writeln('${field.name}_ = *$pointerFieldName;');
            });
          }
        }
      }
    });
    indent.addln('');
  }

  for (final Api api in root.apis) {
    //_writeCodecSource(indent, api, root);
    indent.addln('');
    if (api.location == ApiLocation.host) {
      _writeHostApiSource(indent, api);

      indent.addln('');
      indent.format('''
flutter::EncodableMap ${api.name}::WrapError(const std::exception& exception) {
\treturn flutter::EncodableMap({
\t\t{flutter::EncodableValue("${Keys.errorMessage}"), flutter::EncodableValue(exception.what())},
\t\t{flutter::EncodableValue("${Keys.errorCode}"), flutter::EncodableValue("Error")},
\t\t{flutter::EncodableValue("${Keys.errorDetails}"), flutter::EncodableValue()}
\t});
}
flutter::EncodableMap ${api.name}::WrapError(const FlutterError& error) {
\treturn flutter::EncodableMap({
\t\t{flutter::EncodableValue("${Keys.errorMessage}"), flutter::EncodableValue(error.message)},
\t\t{flutter::EncodableValue("${Keys.errorCode}"), flutter::EncodableValue(error.code)},
\t\t{flutter::EncodableValue("${Keys.errorDetails}"), flutter::EncodableValue(error.details)}
\t});
}''');
      indent.addln('');
    } else if (api.location == ApiLocation.flutter) {
      _writeFlutterApiSource(indent, api);
    }
  }

  if (options.namespace != null) {
    indent.writeln('} // namespace');
  }
}
