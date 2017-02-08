$:.unshift(File.dirname(__FILE__)) unless $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

require 'set'
require 'fileutils'
require 'dataMetaDom/help'
require 'dataMetaDom/field'
require 'dataMetaDom/pojo' # we borrow some useful methods from the POJO Lexer
require 'erb'
require 'ostruct'

module DataMetaDom
=begin rdoc
Definition for generating Python basic classes that do not relate to serialization layer.

For command line details either check the new method's source or the README.rdoc file, the usage section.
=end
module PythonLexer
    include DataMetaDom

    # Standard header for every __init__.py file
    INIT_PY_HEADER = %q<
# see https://docs.python.org/3/library/pkgutil.html
# without this, Python will have trouble finding packages that share some common tree off the root
from pkgutil import extend_path
__path__ = extend_path(__path__, __name__)

>

# The top of each model file.
    MODEL_HEADER = %q|# This file is generated by DataMeta DOM. Do not edit manually!
# package %s

import re

from datameta_core.base import Verifiable, DateTime, Migrator, SemVer
from datameta_core.canned_re import CannedRe

# noinspection PyCompatibility
from enum import Enum

|

# Augment the RegExRoster class with Python specifics
    class PyRegExRoster < RegExRoster
# converts the registry to the Python variable -- compiled Re
        def to_patterns
            i_to_r.keys.map { |ix|
                r = i_to_r[ix]
                rx = r.r.to_s
                %<#{RegExRoster.ixToVarName(ix)} = re.compile(#{rx.inspect}) # #{r.vars.to_a.sort.join(', ')}>
            }.join("\n#{INDENT}")
        end

# converts the registry to the verification code for the verify() method
        def to_verifications(baseName)
            result = (canned.keys.map { |r|
                r = canned[r]
                vs = r.vars.to_a.sort
                vs.map { |v|
                    rx = r.r.to_s
                    %<\n#{INDENT*2}if(#{r.req? ? '' : "self.__#{v} is not None and "}CannedRe.CANNED_RES[#{rx.inspect}].match(self.__#{v}) is None):
#{INDENT*3}raise AttributeError("Property \\"#{v}\\" == {{%s}} didn't match canned expression \\"#{rx}\\"" % self.__#{v} )>
                }
            }).flatten
            (result << i_to_r.keys.map { |ix|
                r = i_to_r[ix]
                vs = r.vars.to_a.sort
                rv = "#{baseName}.#{RegExRoster.ixToVarName(ix)}"
                vs.map { |v|
                    %<\n#{INDENT*2}if(#{r.req? ? '' : "self.__#{v} is not None and "}#{rv}.match(self.__#{v}) is None):
#{INDENT*3}raise AttributeError("Property \\"#{v}\\" == {{%s}} didn't match custom expression {{%s}}" %(self.__#{v}, #{rv}))>
                }
            }).flatten
            result.join("\n")
        end
    end

=begin rdoc
Generates Python sources for the model, the "plain" Python part, without fancy dependencies.
* Parameters
  * +parser+ - instance of Model
  * +outRoot+ - output directory
=end
    def genPy(model, outRoot)
        firstRecord = model.records.values.first
        @pyPackage, baseName, packagePath = DataMetaDom::PojoLexer::assertNamespace(firstRecord.name)

        # Next: replace dots with underscores.
        # The path also adjusted accordingly.
        #
        # Rationale for this, quoting PEP 8:
        #
        #    Package and Module Names
        #
        #    Modules should have short, all-lowercase names. Underscores can be used in the module name if it improves
        #    readability. Python packages should also have short, all-lowercase names, although the use of underscores
        #    is discouraged.
        #
        # Short and all-lowercase names, and improving readability if you have complex system and need long package names,
        # is "discouraged". Can't do this here, our system is more complicated for strictly religous, "pythonic" Python.
        # A tool must be enabling, and in this case, this irrational ruling gets in the way.
        # And dots are a no-no, Python can't find packages with complicated package structures and imports.
        #
        # Hence, we opt for long package names with underscores for distinctiveness and readability:
        @pyPackage = @pyPackage.gsub('.', '_')
        packagePath = packagePath.gsub('/', '_')
        destDir = File.join(outRoot, packagePath)
        FileUtils.mkdir_p destDir
        # build the package path and create __init__.py files in each package's dir if it's not there.
        @destDir = packagePath.split(File::SEPARATOR).reduce(outRoot){ |s,v|
            r = s.empty? ? v : File.join(s, v) # next package dir
            FileUtils.mkdir_p r # create if not there
            # create the __init__.py with proper content if it's not there
            df = File.join(r, '__init__.py'); IO.write(df, INIT_PY_HEADER, mode: 'wb') unless r == outRoot || File.file?(df)
            r # pass r for the next reduce iteration
        }
        vars =  OpenStruct.new # for template's local variables. ERB does not make them visible to the binding
        modelFile = File.join(@destDir, 'model.py')
        [modelFile].each{|f| FileUtils.rm f if File.file?(f)}
        IO.write(modelFile, MODEL_HEADER % @pyPackage, mode: 'wb')
        (model.records.values + model.enums.values).each { |srcE| # it is important that the records render first
            _, baseName, _ = DataMetaDom::PojoLexer::assertNamespace(srcE.name)

            pyClassName = baseName

            case
                when srcE.kind_of?(DataMetaDom::Record)
                    fields = srcE.fields
                    rxRoster = PyRegExRoster.new
                    eqHashFields = srcE.identity ? srcE.identity.args : fields.keys.sort
                    reqFields = fields.values.select{|f| f.isRequired }.map{|f| f.name}
                    verCalls = reqFields.map{|r| %<if(self.__#{r} is None): missingFields.append("#{r}");>}.join("\n#{INDENT * 2}")
                    fieldVerifications = ''
                    fields.each_key { |k|
                        f = fields[k]
                        dt = f.dataType
                        rxRoster.register(f) if f.regex
                        if f.trgType # Maps: if either the key or the value is verifiable, do it
                            mainVf = model.records[dt.type] # main data type is verifiable
                            trgVf = model.records[f.trgType.type]  # target type is verifiable
                            if mainVf || trgVf
                                fieldVerifications << "\n#{INDENT*2}#{!f.isRequired ? "if(self.__#{f.name} is not None):\n#{INDENT*3}" : '' }for k, v in self.__#{f.name}.iteritems():#{mainVf ? 'k.verify();' : ''} #{trgVf ? 'v.verify()' :''}\n"
                            end
                        end

                        if model.records[dt.type] && !f.trgType # maps handled separately
                            fieldVerifications << "\n#{INDENT*2}#{!f.isRequired ? "if(self.__#{f.name} is not None): " : '' }#{f.aggr ? "[v___#{f.name}.verify() for v___#{f.name} in self.__#{f.name} ]" : "self.__#{f.name}.verify()"}"
                            # the Verifiable::verify method reference works just fine, tested it: Java correctly calls the method on the object
                        end
                    }
                    IO::write(File.join(@destDir, 'model.py'),
                              ERB.new(IO.read(File.join(File.dirname(__FILE__), '../../tmpl/python/entity.erb')),
                                      $SAFE, '%<>').result(binding), mode: 'ab')
                when srcE.kind_of?(DataMetaDom::Mappings)
#                        FIXME -- implement!!!
                when srcE.kind_of?(DataMetaDom::Enum)
                    IO.write(modelFile, %|#{baseName} = Enum("#{baseName}", "#{srcE.rawVals.join(' ')}")\n\n|, mode: 'ab')
#                        # handled below, bundled in one huge file
                when srcE.kind_of?(DataMetaDom::BitSet)
#                        FIXME -- implement!!!
                else
                    raise "Unsupported Entity: #{srcE.inspect}"
            end
        }
    end

end
end