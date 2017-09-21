mkdir pkg
mkdir pkg\DataModel

copy Mutex_Package\metadata.xml                                                                     pkg
copy Mutex_Package\DataModel\datamodel.xml                                                          pkg\DataModel


cd pkg
set fn="..\Mutex_Package.zip"
del %fn%
"c:\Program Files\7-Zip\7z.exe" a %fn% *
cd ..

rmdir /s /q pkg
