mvn deploy:deploy-file \
  -Dfile=scip.jar \
  -DpomFile=pom.xml \
  -DrepositoryId=prometeia \
  -Durl=https://nexus.prometeiasaas.it/repository/snapshots/