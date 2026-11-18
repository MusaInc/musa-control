export function canInvite({app,build,version,beta,review,group,groupBuilds}) {
 return app.id==='6831994013' && app.attributes.bundleId==='uk.co.musastudios.musacontrol'
  && build.id==='b9d82af1-1de3-4765-8143-a014afadb398' && build.attributes.version==='116'
  && build.attributes.processingState==='VALID' && build.attributes.expired===false
  && new Date(build.attributes.expirationDate).getTime()>Date.now()
  && version.attributes.version==='0.4.3'
  && review.attributes.betaReviewState==='APPROVED'
  && ['READY_FOR_BETA_TESTING','IN_BETA_TESTING'].includes(beta.attributes.externalBuildState)
  && group.attributes.name==='Hafsa' && group.attributes.isInternalGroup===false
  && group.attributes.publicLinkEnabled!==true
  && groupBuilds.length===1 && groupBuilds[0].id===build.id;
}
